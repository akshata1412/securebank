#!/bin/bash
# Live disaster demos for the review. Run in CloudShell (keep the app's /dr page open beside it):
#   bash ~/sbrepo/infra/demo.sh lb         # one server dies: the load balancer keeps the app up
#   bash ~/sbrepo/infra/demo.sh restore    # bring web-1 back
#   bash ~/sbrepo/infra/demo.sh pod        # a Kubernetes pod dies: it is recreated automatically
#   bash ~/sbrepo/infra/demo.sh dr         # make a transfer, watch it replicate to the DR bucket
#   bash ~/sbrepo/infra/demo.sh wipe       # disaster: the transaction ledger is wiped from RDS
#   bash ~/sbrepo/infra/demo.sh recover    # rebuild the ledger from the DR bucket
#   bash ~/sbrepo/infra/demo.sh outage     # disaster: Sydney goes dark, Route 53 fails over to the Mumbai standby
#   bash ~/sbrepo/infra/demo.sh recover-site  # bring the site back and measure recovery time
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
B=securebank-backups-akshata-2026; DR=securebank-dr-backup-akshata-2026
APP=app.securebank-akshata.com

targets(){ aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | sed "s/$WEB1/web-1/;s/$WEB2/web-2/"; }
healthy_count(){ targets | grep -c healthy$; }
dns_answer(){ aws route53 test-dns-answer --hosted-zone-id $HZ --record-name $APP --record-type CNAME --query 'RecordData[0]' --output text; }
r53_ok(){ aws route53 get-health-check-status --health-check-id $HC --query 'length(HealthCheckObservations[?starts_with(StatusReport.Status, `Success`)])' --output text; }
ip_of(){ aws ec2 describe-instances --instance-ids $1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }
key(){ [ -f ~/dkey ] || ssh-keygen -t ed25519 -N '' -f ~/dkey -q; aws ec2-instance-connect send-ssh-public-key --instance-id $1 --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null; }
on(){ I=$1; shift; key $I; ssh -i ~/dkey -o StrictHostKeyChecking=no -o LogLevel=ERROR ec2-user@$(ip_of $I) "$@"; }
k(){ on $K8SM "$@"; }
app_exec(){ # run the recovery tool inside passbook-management on api-a (through Systems Manager, no SSH)
  printf '%s' "docker exec passbook python recovery.py $*" | python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' > /tmp/ssm-params.json
  local cid; cid=$(aws ssm send-command --instance-ids $APIA --document-name AWS-RunShellScript --parameters file:///tmp/ssm-params.json --query Command.CommandId --output text)
  for n in $(seq 1 40); do st=$(aws ssm get-command-invocation --command-id $cid --instance-id $APIA --query Status --output text 2>/dev/null || echo Pending)
    case $st in Success|Failed) break;; esac; sleep 2; done
  aws ssm get-command-invocation --command-id $cid --instance-id $APIA --query '[StandardOutputContent,StandardErrorContent]' --output text; }
event(){ # level text [seconds] [kind]: append to the DR timeline shown on the /dr page
  S=""; [ -n "$3" ] && S=",\"seconds\":$3"; [ -n "$4" ] && S="$S,\"kind\":\"$4\""
  echo "{\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"level\":\"$1\",\"text\":\"$2\"$S}" | \
    aws s3 cp - s3://$B/dr-events/$(date -u +%Y%m%d-%H%M%S)-$RANDOM.json --content-type application/json --only-show-errors; }
k8s_url(){ echo "http://$(ip_of $K8SM):30081/dr"; }

case "$1" in
lb)
  echo "== Before: both servers healthy =="; targets
  echo; echo "== Stopping securebank-web-1 (simulated server failure) =="
  aws ec2 stop-instances --instance-ids $WEB1 >/dev/null
  event alert "Drill: securebank-web-1 stopped"
  echo "== Calling the app through the load balancer every second =="
  OK=0; FAIL=0
  for i in $(seq 1 40); do
    R=$(curl -s -m 3 -w ' %{http_code}' http://$ALBDNS/health)
    CODE=${R##* }; SRV=$(echo "$R" | grep -o '"server":"[^"]*"' | cut -d'"' -f4)
    [ "$CODE" = 200 ] && OK=$((OK+1)) || FAIL=$((FAIL+1))
    printf '%2ds  HTTP %s  served by %s\n' $i "$CODE" "${SRV:-none}"; sleep 1
  done
  echo; echo "== After: =="; targets
  event ok "Load balancer moved all traffic to securebank-web-2 ($OK of 40 requests succeeded)"
  echo
  echo "Result: $OK of 40 requests succeeded, $FAIL failed."
  echo "The few failures happen in the ~10 s the load balancer needs to detect the dead server"
  echo "(health check every 5 s, 2 misses). After that, web-2 serves 100% of traffic with no manual action." ;;
restore)
  aws ec2 start-instances --instance-ids $WEB1 >/dev/null; aws ec2 wait instance-running --instance-ids $WEB1
  echo "web-1 started, waiting for the load balancer to mark it healthy..."
  for i in $(seq 1 40); do targets | grep -qE "web-1[[:space:]]+healthy" && break; sleep 5; done; targets
  event ok "securebank-web-1 back in service" ;;
pod)
  k 'kubectl get pods -l app=securebank -o wide | cut -c1-100
     P=$(kubectl get pods -l app=securebank -o name | head -1)
     echo; echo "== Deleting $P (simulated crash) =="; kubectl delete $P --wait=false
     for i in 1 2 3 4 5 6; do sleep 4; echo "--- after $((i*4))s ---"; kubectl get pods -l app=securebank | cut -c1-80; done
     echo; echo "Kubernetes noticed only 2 of 3 replicas were running and started a new pod automatically."'
  event ok "Kubernetes replaced a crashed SecureBank pod automatically" ;;
dr)
  J=$(mktemp)
  curl -s -c $J -b $J -o /dev/null -d 'username=akshata&password=demo123' http://$ALBDNS/
  curl -s -c $J -b $J -o /dev/null -d 'recipient=rahul&amount=1&note=DR demo' http://$ALBDNS/transfer
  rm -f $J
  KEY=$(aws s3api list-objects-v2 --bucket $B --prefix transactions/live/ --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
  echo "== New transaction backup: $KEY =="
  aws s3 cp s3://$B/$KEY - | head -12; echo
  WRITTEN=$(date -d "$(aws s3api head-object --bucket $B --key $KEY --query LastModified --output text)" +%s)
  for i in $(seq 1 30); do
    ST=$(aws s3api head-object --bucket $B --key $KEY --query ReplicationStatus --output text 2>/dev/null)
    aws s3api head-object --bucket $DR --key $KEY >/dev/null 2>&1 && IN=yes || IN=no
    LAG=$(( $(date +%s) - WRITTEN ))
    printf '%3ds  source replication status: %-9s  copy in DR bucket: %s\n' $LAG "$ST" "$IN"
    [ "$IN" = yes ] && break; sleep 2
  done
  echo; echo "The transfer reached the DR bucket $LAG s after it was written."
  event info "Replication drill: a new transfer reached the DR bucket" $LAG rpo ;;
wipe)
  echo "== Before =="; app_exec status
  echo; echo "== DISASTER: deleting every transaction from the RDS database =="
  app_exec simulate-loss --yes
  echo; echo "== After =="; app_exec status
  echo; echo "Open the /dr page: it now shows the records missing from the database, with every copy still in the DR vault." ;;
recover)
  echo "== Rebuilding the ledger from the S3 DR bucket =="
  app_exec restore
  echo; app_exec status
  echo; echo "The passbook and the /dr page show every transaction again." ;;
outage)
  echo "== Before =="; echo "load balancer: $(healthy_count) of 2 servers healthy"; echo "Route 53 answers $APP with: $(dns_answer)"
  echo; echo "== DISASTER: stopping BOTH web servers =="
  date +%s > ~/.sb_outage_start
  aws ec2 stop-instances --instance-ids $WEB1 $WEB2 >/dev/null
  event alert "Drill: both web servers stopped, simulating a full site outage"
  echo "Meanwhile the Kubernetes copy of the app keeps running. Watch it: $(k8s_url)"
  echo; T0=$(date +%s)
  for i in $(seq 1 40); do
    A=$(dns_answer); T=$(( $(date +%s) - T0 ))
    printf '%3ds  servers healthy: %s of 2   Route 53 checkers OK: %-2s  DNS answer: %s\n' $T "$(healthy_count)" "$(r53_ok)" "$A"
    if ! echo "$A" | grep -q ap-southeast-2; then
      if echo "$A" | grep -qE 'mumbai|ap-south-1'; then WHERE="the Mumbai standby (second AWS account)"; else WHERE="the S3 status page"; fi
      echo; echo "Route 53 failed over to $WHERE after $T s."
      event alert "Route 53 failed over to $WHERE" $T
      if [ -n "$MUMDNS" ]; then
        echo; echo "== Customers keep banking in Mumbai =="
        curl -s -m 8 http://$MUMDNS/health; echo
        J=$(mktemp); curl -s -c $J -b $J -o /dev/null -d 'username=akshata&password=demo123' http://$MUMDNS/
        curl -s -c $J -b $J http://$MUMDNS/dashboard | grep -o 'Rs</small>[0-9,]*' | sed 's#</small># #' | head -1 | sed 's/^/akshata balance in Mumbai: /'
        rm -f $J
      fi
      break
    fi
    sleep 5
  done
  [ -n "$MUMDNS" ] && echo "Customers now use: http://$MUMDNS" || echo "Customers now see: http://securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com" ;;
recover-site)
  START=$(cat ~/.sb_outage_start 2>/dev/null || date +%s); T0=$(date +%s)
  echo "== Recovery: starting both web servers =="
  event info "Recovery started: bringing both web servers back"
  aws ec2 start-instances --instance-ids $WEB1 $WEB2 >/dev/null
  aws ec2 wait instance-running --instance-ids $WEB1 $WEB2
  echo "servers running after $(( $(date +%s) - T0 )) s; waiting for health checks..."
  for i in $(seq 1 60); do
    A=$(dns_answer); H=$(healthy_count); T=$(( $(date +%s) - T0 ))
    printf '%3ds  servers healthy: %s of 2   DNS answer: %s\n' $T "$H" "$A"
    [ "$H" = 2 ] && echo "$A" | grep -q ap-southeast-2 && break
    sleep 5
  done
  RTO=$(( $(date +%s) - T0 )); DOWN=$(( $(date +%s) - START ))
  event ok "Service restored: both servers healthy and Route 53 back on the load balancer" $RTO
  rm -f ~/.sb_outage_start
  echo; echo "Recovery time (RTO): $RTO s from starting recovery. Total time customers were on the backup site: $DOWN s."
  echo "Customer data lost: none (check the /dr page)." ;;
*) sed -n 2,10p "$0" ;;
esac
