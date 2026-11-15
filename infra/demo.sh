#!/bin/bash
# Live failure demos for the review. Run in CloudShell:
#   bash ~/sbrepo/infra/demo.sh lb        # kill web-1, app stays up through web-2
#   bash ~/sbrepo/infra/demo.sh restore   # bring web-1 back
#   bash ~/sbrepo/infra/demo.sh pod       # delete a Kubernetes pod, watch it self-heal
#   bash ~/sbrepo/infra/demo.sh dr        # make a transfer, watch it replicate to the DR bucket
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
B=securebank-backups-akshata-2026; DR=securebank-dr-backup-akshata-2026
targets(){ aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | sed "s/$WEB1/web-1/;s/$WEB2/web-2/"; }
k(){ IP=$(aws ec2 describe-instances --instance-ids $K8SM --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
     [ -f ~/dkey ] || ssh-keygen -t ed25519 -N '' -f ~/dkey -q
     aws ec2-instance-connect send-ssh-public-key --instance-id $K8SM --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null
     ssh -i ~/dkey -o StrictHostKeyChecking=no -o LogLevel=ERROR ec2-user@$IP "$@"; }

case "$1" in
lb)
  echo "== Before: both servers healthy =="; targets
  echo; echo "== Stopping securebank-web-1 (simulated server failure) =="
  aws ec2 stop-instances --instance-ids $WEB1 >/dev/null
  echo "== Calling the app through the load balancer every second =="
  for i in $(seq 1 40); do
    R=$(curl -s -m 3 -w ' %{http_code}' http://$ALBDNS/health)
    CODE=${R##* }; SRV=$(echo "$R" | grep -o '"server":"[^"]*"' | cut -d'"' -f4)
    printf '%2ds  HTTP %s  served by %s\n' $i "$CODE" "${SRV:-none}"; sleep 1
  done
  echo; echo "== After: =="; targets
  echo "Users never lost the app: web-2 took all the traffic." ;;
restore)
  aws ec2 start-instances --instance-ids $WEB1 >/dev/null; aws ec2 wait instance-running --instance-ids $WEB1
  echo "web-1 started, waiting for the load balancer to mark it healthy..."
  for i in $(seq 1 40); do targets | grep -qE "web-1[[:space:]]+healthy" && break; sleep 5; done; targets ;;
pod)
  k 'kubectl get pods -l app=securebank -o wide | cut -c1-100
     P=$(kubectl get pods -l app=securebank -o name | head -1)
     echo; echo "== Deleting $P (simulated crash) =="; kubectl delete $P --wait=false
     for i in 1 2 3 4 5 6; do sleep 4; echo "--- after $((i*4))s ---"; kubectl get pods -l app=securebank | cut -c1-80; done
     echo; echo "Kubernetes noticed only 2 of 3 replicas were running and started a new pod automatically."' ;;
dr)
  J=$(mktemp)
  curl -s -c $J -b $J -o /dev/null -d 'username=akshata&password=demo123' http://$ALBDNS/
  curl -s -c $J -b $J -o /dev/null -d 'recipient=rahul&amount=1&note=DR demo' http://$ALBDNS/transfer
  rm -f $J
  KEY=$(aws s3api list-objects-v2 --bucket $B --prefix transactions/live/ --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
  echo "== New transaction backup: $KEY =="
  aws s3 cp s3://$B/$KEY - | head -12
  for i in $(seq 1 12); do
    ST=$(aws s3api head-object --bucket $B --key $KEY --query ReplicationStatus --output text 2>/dev/null)
    aws s3api head-object --bucket $DR --key $KEY >/dev/null 2>&1 && IN=yes || IN=no
    printf '%3ds  source replication status: %-9s  copy in DR bucket: %s\n' $((i*5)) "$ST" "$IN"
    [ "$IN" = yes ] && break; sleep 5
  done ;;
*) sed -n 2,6p "$0" ;;
esac
