#!/bin/bash
# Build the secure three-tier layout in Sydney. Run in CloudShell, one phase at a time:
#   bash ~/sbrepo/infra/09-three-tier.sh secrets   # DB password, tokens -> SSM Parameter Store; SSM access for EC2
#   bash ~/sbrepo/infra/09-three-tier.sh network   # data subnets, NAT instance, firewall chain (security groups)
#   bash ~/sbrepo/infra/09-three-tier.sh ilb       # internal load balancer with path rules for the 3 microservices
#   bash ~/sbrepo/infra/09-three-tier.sh api       # api-a / api-b in private subnets running the microservices
#   bash ~/sbrepo/infra/09-three-tier.sh web       # web-1 / web-2 run the web tier only (no DB access)
#   bash ~/sbrepo/infra/09-three-tier.sh rds       # move RDS into the private data subnets, public access off
#   bash ~/sbrepo/infra/09-three-tier.sh multiaz   # replication across AZs (Multi-AZ, or a replica in AZ b)
#   bash ~/sbrepo/infra/09-three-tier.sh nacl      # separate subnet firewall (network ACL) for the database tier
#   bash ~/sbrepo/infra/09-three-tier.sh waf       # AWS WAF in front of the public load balancer
#   bash ~/sbrepo/infra/09-three-tier.sh lockdown  # close SSH on the web tier, deep health check for Route 53
#   bash ~/sbrepo/infra/09-three-tier.sh status
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
ROLE=SecureBank-EC2-S3-Role
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
GH=ghcr.io/akshata1412
save(){ grep -q "^$1=" ~/securebank-vpc.env && sed -i "s#^$1=.*#$1=$2#" ~/securebank-vpc.env || echo "$1=$2" >> ~/securebank-vpc.env; export $1=$2; }
tag(){ aws ec2 create-tags --resources "$1" --tags Key=Name,Value="$2" Key=Project,Value=SecureBank; }
sg(){ # name description -> id (create once)
  local id; id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$1 Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = None ]; then id=$(aws ec2 create-security-group --group-name $1 --description "$2" --vpc-id $VPC --query GroupId --output text); tag $id $1; fi; echo $id; }
allow(){ aws ec2 authorize-security-group-ingress --group-id $1 --ip-permissions "$2" >/dev/null 2>&1 || true; }
param(){ aws ssm get-parameter --name $1 --with-decryption --query Parameter.Value --output text; }
ssm_run(){ # "instance ids" "commands" -> waits and prints each instance's output
  local ids=$1 cmd=$2 cid
  printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' > /tmp/ssm-params.json
  cid=$(aws ssm send-command --instance-ids $ids --document-name AWS-RunShellScript --parameters file:///tmp/ssm-params.json \
        --timeout-seconds 600 --query Command.CommandId --output text)
  for i in $ids; do
    for n in $(seq 1 90); do
      st=$(aws ssm get-command-invocation --command-id $cid --instance-id $i --query Status --output text 2>/dev/null || echo Pending)
      case $st in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 4
    done
    echo "--- $i: $st"; aws ssm get-command-invocation --command-id $cid --instance-id $i --query '[StandardOutputContent,StandardErrorContent]' --output text | tail -15
  done; }

case "$1" in
secrets)
  echo "== EC2 role: Systems Manager access (deploy without SSH) and read access to /securebank/* parameters =="
  aws iam attach-role-policy --role-name $ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  ACCT=$(aws sts get-caller-identity --query Account --output text)
  cat > /tmp/ssm-read.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
 "Resource":"arn:aws:ssm:ap-southeast-2:$ACCT:parameter/securebank/*"}]}
JSON
  aws iam put-role-policy --role-name $ROLE --policy-name SecureBank-Read-Secrets --policy-document file:///tmp/ssm-read.json
  echo "== Secrets into Parameter Store (SecureString). The DB password is read from web-1, never typed =="
  rm -f ~/dkey ~/dkey.pub; ssh-keygen -t ed25519 -N '' -f ~/dkey -q
  aws ec2-instance-connect send-ssh-public-key --instance-id $WEB1 --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null
  IP=$(aws ec2 describe-instances --instance-ids $WEB1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  DBPW=$(ssh -i ~/dkey -o StrictHostKeyChecking=no -o LogLevel=ERROR ec2-user@$IP "grep \"'password'\" /opt/securebank/app.py | cut -d\"'\" -f4")
  rm -f ~/dkey ~/dkey.pub
  [ -n "$DBPW" ] || { echo "could not read the DB password from web-1"; exit 1; }
  [ -f ~/.sb_secret_key ] || openssl rand -hex 24 > ~/.sb_secret_key
  [ -f ~/.sb_repl_token ] || openssl rand -hex 24 > ~/.sb_repl_token
  [ -f ~/.sb_internal_token ] || openssl rand -hex 24 > ~/.sb_internal_token
  put(){ aws ssm put-parameter --name $1 --type SecureString --value "$2" --overwrite >/dev/null && echo "  stored $1"; }
  put /securebank/db-password "$DBPW"
  put /securebank/secret-key "$(cat ~/.sb_secret_key)"
  put /securebank/internal-token "$(cat ~/.sb_internal_token)"
  put /securebank/repl-token "$(cat ~/.sb_repl_token)"
  echo SECRETS_DONE ;;

network)
  echo "== Data subnets for the database (no route to the internet at all) =="
  mk(){ local s; s=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$3 --query 'Subnets[0].SubnetId' --output text)
        [ "$s" = None ] && { s=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block $1 --availability-zone $2 --query Subnet.SubnetId --output text); tag $s $3; }; echo $s; }
  save DATAA $(mk 10.0.21.0/24 ap-southeast-2a securebank-data-a)
  save DATAB $(mk 10.0.22.0/24 ap-southeast-2b securebank-data-b)
  RT=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=securebank-data-rt --query 'RouteTables[0].RouteTableId' --output text)
  [ "$RT" = None ] && { RT=$(aws ec2 create-route-table --vpc-id $VPC --query RouteTable.RouteTableId --output text); tag $RT securebank-data-rt; }
  save DATART $RT
  for S in $DATAA $DATAB; do aws ec2 associate-route-table --route-table-id $RT --subnet-id $S >/dev/null 2>&1 || true; done
  tag $PRIA securebank-app-a; tag $PRIB securebank-app-b
  echo "== Firewall chain: one security group per tier =="
  save ILBSG $(sg securebank-internal-lb-sg "Internal load balancer - HTTP from the web tier only")
  save APISG $(sg securebank-api-sg "Microservices - ports 5001-5003 from the internal load balancer only")
  save DBSG $(sg securebank-db-sg "Database - MySQL from the microservices only (separate firewall)")
  save NATSG $(sg securebank-nat-sg "NAT instance - outbound for private subnets")
  K8SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=securebank-k8s-sg --query 'SecurityGroups[0].GroupId' --output text); save K8SG $K8SG
  allow $ILBSG "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$WEBSG,Description=web tier}]"
  allow $APISG "IpProtocol=tcp,FromPort=5001,ToPort=5003,UserIdGroupPairs=[{GroupId=$ILBSG,Description=internal load balancer}]"
  allow $DBSG "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$APISG,Description=microservices on EC2}]"
  allow $DBSG "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$K8SG,Description=microservice pods on Kubernetes}]"
  allow $NATSG "IpProtocol=-1,IpRanges=[{CidrIp=10.0.0.0/16,Description=private subnets}]"
  echo "== NAT instance so private servers can download images and updates (outbound only) =="
  NAT=$(aws ec2 describe-instances --filters Name=tag:Name,Values=securebank-nat Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$NAT" = None ]; then
    cat > /tmp/nat-userdata.sh <<'UD'
#!/bin/bash
dnf install -y iptables-services
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-nat.conf && sysctl --system
IF=$(ip route | awk '/default/ {print $5; exit}')
iptables -t nat -A POSTROUTING -o $IF -j MASQUERADE && iptables -F FORWARD
service iptables save && systemctl enable --now iptables
UD
    NAT=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro --subnet-id $PUBA --security-group-ids $NATSG \
          --iam-instance-profile Name=$ROLE --user-data file:///tmp/nat-userdata.sh \
          --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=securebank-nat},{Key=Project,Value=SecureBank}]" \
          --query 'Instances[0].InstanceId' --output text)
    aws ec2 wait instance-running --instance-ids $NAT
    aws ec2 modify-instance-attribute --instance-id $NAT --no-source-dest-check
  fi
  save NAT $NAT
  aws ec2 replace-route --route-table-id $PRIRT --destination-cidr-block 0.0.0.0/0 --instance-id $NAT 2>/dev/null || \
    aws ec2 create-route --route-table-id $PRIRT --destination-cidr-block 0.0.0.0/0 --instance-id $NAT >/dev/null
  # Until RDS moves into the data subnets it is still reached over the VPC peering link
  [ -n "$PCX" ] && aws ec2 create-route --route-table-id $PRIRT --destination-cidr-block 172.31.0.0/16 --vpc-peering-connection-id $PCX >/dev/null 2>&1 || true
  echo "subnets: data-a=$DATAA data-b=$DATAB  NAT=$NAT  SGs: ilb=$ILBSG api=$APISG db=$DBSG"
  echo NETWORK_DONE ;;

ilb)
  echo "== Internal load balancer (not internet-facing) in the private app subnets =="
  ILB=$(aws elbv2 describe-load-balancers --names securebank-internal-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
  if [ -z "$ILB" ] || [ "$ILB" = None ]; then
    ILB=$(aws elbv2 create-load-balancer --name securebank-internal-alb --scheme internal --type application \
          --subnets $PRIA $PRIB --security-groups $ILBSG --tags Key=Project,Value=SecureBank --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  fi
  save ILB $ILB
  save ILBDNS $(aws elbv2 describe-load-balancers --load-balancer-arns $ILB --query 'LoadBalancers[0].DNSName' --output text)
  tg(){ local a; a=$(aws elbv2 describe-target-groups --names $1 --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
        [ -z "$a" ] || [ "$a" = None ] && a=$(aws elbv2 create-target-group --name $1 --protocol HTTP --port $2 --vpc-id $VPC \
          --health-check-path /health --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
          --query 'TargetGroups[0].TargetGroupArn' --output text); echo $a; }
  save TGUSERS $(tg sb-users 5001); save TGACCOUNTS $(tg sb-accounts 5002); save TGPASSBOOK $(tg sb-passbook 5003)
  for T in $TGUSERS $TGACCOUNTS $TGPASSBOOK; do
    aws elbv2 modify-target-group-attributes --target-group-arn $T --attributes Key=deregistration_delay.timeout_seconds,Value=5 >/dev/null; done
  L=$(aws elbv2 describe-listeners --load-balancer-arn $ILB --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)
  if [ -z "$L" ] || [ "$L" = None ]; then
    L=$(aws elbv2 create-listener --load-balancer-arn $ILB --protocol HTTP --port 80 \
        --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"404","ContentType":"text/plain","MessageBody":"no such service"}}]' \
        --query 'Listeners[0].ListenerArn' --output text)
    rule(){ aws elbv2 create-rule --listener-arn $L --priority $1 --conditions "Field=path-pattern,Values=/$2,/$2/*" \
            --actions Type=forward,TargetGroupArn=$3 >/dev/null; echo "  /$2 -> $(basename $(dirname $3))"; }
    rule 10 users $TGUSERS; rule 20 accounts $TGACCOUNTS; rule 30 passbook $TGPASSBOOK
  fi
  echo "internal load balancer: $ILBDNS"
  echo ILB_DONE ;;

api)
  echo "== Microservice servers api-a (AZ a) and api-b (AZ b): private subnets, no public IP =="
  DBHOST=$(aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].Endpoint.Address' --output text)
  cat > /tmp/api-userdata.sh <<UD
#!/bin/bash
dnf install -y docker && systemctl enable --now docker
cat > /usr/local/bin/sb-api-deploy <<'SCRIPT'
#!/bin/bash
# Pull the latest microservice images and (re)start them. Secrets come from SSM Parameter Store.
set -e
export AWS_DEFAULT_REGION=ap-southeast-2
P(){ aws ssm get-parameter --name \$1 --with-decryption --query Parameter.Value --output text; }
DBPW=\$(P /securebank/db-password); TOK=\$(P /securebank/internal-token); REPL=\$(P /securebank/repl-token)
T=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
AZ=\$(curl -s -H "X-aws-ec2-metadata-token: \$T" http://169.254.169.254/latest/meta-data/placement/availability-zone)
NAME=\$(curl -s -H "X-aws-ec2-metadata-token: \$T" http://169.254.169.254/latest/meta-data/tags/instance/Name || hostname)
DBHOST=\${DBHOST:-$DBHOST}
port=5001
for s in users accounts passbook; do
  docker pull -q $GH/securebank-\$s:latest
  docker rm -f \$s >/dev/null 2>&1 || true
  docker run -d --name \$s --restart always -p \$port:5000 -e DB_HOST=\$DBHOST -e DB_USER=admin -e DB_PASSWORD="\$DBPW" \
    -e INTERNAL_TOKEN=\$TOK -e REPL_TOKEN=\$REPL -e S3_BUCKET=securebank-backups-akshata-2026 \
    -e DR_BUCKET=securebank-dr-backup-akshata-2026 -e AWS_REGION=ap-southeast-2 -e SERVER_ID="\$NAME (\$AZ)" \
    $GH/securebank-\$s:latest >/dev/null
  echo "\$s on port \$port"; port=\$((port+1))
done
SCRIPT
chmod +x /usr/local/bin/sb-api-deploy
for i in \$(seq 1 30); do curl -s -m 3 https://ghcr.io >/dev/null && break; sleep 5; done
/usr/local/bin/sb-api-deploy
UD
  launch(){ local id; id=$(aws ec2 describe-instances --filters Name=tag:Name,Values=$2 Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
    [ "$id" = None ] && id=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro --subnet-id $1 --security-group-ids $APISG \
      --no-associate-public-ip-address --iam-instance-profile Name=$ROLE --user-data file:///tmp/api-userdata.sh \
      --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2,InstanceMetadataTags=enabled \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$2},{Key=Project,Value=SecureBank}]" \
      --query 'Instances[0].InstanceId' --output text); echo $id; }
  save APIA $(launch $PRIA securebank-api-a); save APIB $(launch $PRIB securebank-api-b)
  aws ec2 wait instance-running --instance-ids $APIA $APIB
  aws elbv2 register-targets --target-group-arn $TGUSERS --targets Id=$APIA,Port=5001 Id=$APIB,Port=5001
  aws elbv2 register-targets --target-group-arn $TGACCOUNTS --targets Id=$APIA,Port=5002 Id=$APIB,Port=5002
  aws elbv2 register-targets --target-group-arn $TGPASSBOOK --targets Id=$APIA,Port=5003 Id=$APIB,Port=5003
  echo "waiting for the 6 microservice containers to pass health checks (image pulls take a few minutes)..."
  for n in $(seq 1 60); do
    H=0; for T in $TGUSERS $TGACCOUNTS $TGPASSBOOK; do
      H=$((H + $(aws elbv2 describe-target-health --target-group-arn $T --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text))); done
    printf '\r  healthy: %s of 6 ' $H; [ $H = 6 ] && break; sleep 10
  done; echo
  echo API_DONE ;;

web)
  echo "== web-1 / web-2: web tier only. API_URL = internal load balancer; no database password =="
  ssm_run "$WEB1 $WEB2" "set -e
export AWS_DEFAULT_REGION=ap-southeast-2
P(){ aws ssm get-parameter --name \$1 --with-decryption --query Parameter.Value --output text; }
T=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
IID=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" http://169.254.169.254/latest/meta-data/instance-id)
AZ=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" http://169.254.169.254/latest/meta-data/placement/availability-zone)
docker pull -q $GH/securebank-web:latest
docker rm -f securebank-app >/dev/null 2>&1 || true
docker run -d --name securebank-app --restart always -p 80:80 -e API_URL=http://$ILBDNS \
  -e INTERNAL_TOKEN=\$(P /securebank/internal-token) -e SECRET_KEY=\$(P /securebank/secret-key) \
  -e SERVER_ID=\"\$IID (\$AZ)\" -e TARGET_GROUP_ARN=$TG -e HEALTH_CHECK_ID=$HC -e AWS_REGION=ap-southeast-2 \
  $GH/securebank-web:latest >/dev/null
rm -f /opt/securebank/app.py   # the old monolith copy held the DB password; the web tier no longer needs it
sleep 3; curl -s localhost/health/deep | head -c 300; echo"
  echo WEB_DONE ;;

rds)
  echo "== Move RDS into the private data subnets with public access turned off =="
  aws rds create-db-subnet-group --db-subnet-group-name securebank-data-subnets --db-subnet-group-description "SecureBank database tier (private)" \
    --subnet-ids $DATAA $DATAB >/dev/null 2>&1 || true
  aws rds modify-db-instance --db-instance-identifier securebank-db --db-subnet-group-name securebank-data-subnets \
    --vpc-security-group-ids $DBSG --no-publicly-accessible --apply-immediately --query 'DBInstance.DBInstanceStatus' --output text
  echo "RDS is moving (about 10-15 minutes, the app is briefly unavailable)..."
  sleep 60; aws rds wait db-instance-available --db-instance-identifier securebank-db
  aws rds describe-db-instances --db-instance-identifier securebank-db \
    --query 'DBInstances[0].[DBSubnetGroup.VpcId,PubliclyAccessible,AvailabilityZone,Endpoint.Address]' --output text
  echo RDS_DONE ;;

multiaz)
  echo "== Replication across Availability Zones =="
  if aws rds modify-db-instance --db-instance-identifier securebank-db --multi-az --apply-immediately --query 'DBInstance.DBInstanceStatus' --output text; then
    echo "Multi-AZ requested: RDS builds a synchronous standby in the other AZ (10-20 minutes)..."
    sleep 60; aws rds wait db-instance-available --db-instance-identifier securebank-db
    aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].[MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]' --output text
    save DBHA multiaz
  else
    echo "Multi-AZ refused (free plan?). Fallback: an asynchronous read replica in the other AZ."
    PRIMARY_AZ=$(aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].AvailabilityZone' --output text)
    OTHER=ap-southeast-2b; [ "$PRIMARY_AZ" = ap-southeast-2b ] && OTHER=ap-southeast-2a
    aws rds create-db-instance-read-replica --db-instance-identifier securebank-db-replica --source-db-instance-identifier securebank-db \
      --db-instance-class db.t3.micro --availability-zone $OTHER --no-publicly-accessible --vpc-security-group-ids $DBSG \
      --query 'DBInstance.DBInstanceStatus' --output text
    sleep 60; aws rds wait db-instance-available --db-instance-identifier securebank-db-replica
    save DBHA replica
  fi
  echo MULTIAZ_DONE ;;

nacl)
  echo "== Separate subnet firewall (network ACL) for the database tier =="
  NACL=$(aws ec2 describe-network-acls --filters Name=tag:Name,Values=securebank-data-nacl --query 'NetworkAcls[0].NetworkAclId' --output text)
  if [ "$NACL" = None ]; then
    NACL=$(aws ec2 create-network-acl --vpc-id $VPC --query NetworkAcl.NetworkAclId --output text); tag $NACL securebank-data-nacl
    e(){ aws ec2 create-network-acl-entry --network-acl-id $NACL --rule-action allow "$@"; }
    # In: MySQL from the app subnets (microservices) and the public subnets (Kubernetes pods, replication relay)
    e --ingress --rule-number 100 --protocol tcp --port-range From=3306,To=3306 --cidr-block 10.0.11.0/24
    e --ingress --rule-number 110 --protocol tcp --port-range From=3306,To=3306 --cidr-block 10.0.12.0/24
    e --ingress --rule-number 120 --protocol tcp --port-range From=3306,To=3306 --cidr-block 10.0.1.0/24
    e --ingress --rule-number 130 --protocol tcp --port-range From=3306,To=3306 --cidr-block 10.0.2.0/24
    # Between the two data subnets (Multi-AZ standby / replica traffic)
    e --ingress --rule-number 200 --protocol -1 --cidr-block 10.0.21.0/24
    e --ingress --rule-number 210 --protocol -1 --cidr-block 10.0.22.0/24
    # Out: replies to the VPC (stateless, so ephemeral ports) and data-subnet traffic. Everything else is denied.
    e --egress --rule-number 100 --protocol tcp --port-range From=1024,To=65535 --cidr-block 10.0.0.0/16
    e --egress --rule-number 200 --protocol -1 --cidr-block 10.0.21.0/24
    e --egress --rule-number 210 --protocol -1 --cidr-block 10.0.22.0/24
  fi
  save DATANACL $NACL
  for S in $DATAA $DATAB; do
    A=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$S --query "NetworkAcls[0].Associations[?SubnetId=='$S'].NetworkAclAssociationId | [0]" --output text)
    aws ec2 replace-network-acl-association --association-id $A --network-acl-id $NACL >/dev/null
  done
  echo "data subnets now use $NACL"
  echo NACL_DONE ;;

waf)
  echo "== AWS WAF web ACL on the public load balancer =="
  cat > /tmp/waf-rules.json <<'JSON'
[
 {"Name":"aws-common","Priority":10,"Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesCommonRuleSet",
   "ExcludedRules":[{"Name":"SizeRestrictions_BODY"}]}},"OverrideAction":{"None":{}},
   "VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"aws-common"}},
 {"Name":"aws-sqli","Priority":20,"Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesSQLiRuleSet"}},
   "OverrideAction":{"None":{}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"aws-sqli"}},
 {"Name":"aws-bad-inputs","Priority":30,"Statement":{"ManagedRuleGroupStatement":{"VendorName":"AWS","Name":"AWSManagedRulesKnownBadInputsRuleSet"}},
   "OverrideAction":{"None":{}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"aws-bad-inputs"}},
 {"Name":"rate-limit","Priority":40,"Statement":{"RateBasedStatement":{"Limit":500,"AggregateKeyType":"IP"}},
   "Action":{"Block":{}},"VisibilityConfig":{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"rate-limit"}}
]
JSON
  ACL=$(aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='securebank-waf'].ARN | [0]" --output text)
  [ "$ACL" = None ] && ACL=$(aws wafv2 create-web-acl --name securebank-waf --scope REGIONAL --default-action Allow={} \
      --rules file:///tmp/waf-rules.json --visibility-config SampledRequestsEnabled=true,CloudWatchMetricsEnabled=true,MetricName=securebank-waf \
      --query Summary.ARN --output text)
  save WAFACL $ACL
  sleep 5; aws wafv2 associate-web-acl --web-acl-arn $ACL --resource-arn $ALB
  echo "WAF attached. Test: curl \"http://$ALBDNS/?id=1%27%20OR%201=1--\" should return 403"
  echo WAF_DONE ;;

lockdown)
  echo "== Close SSH on the web tier (deploys go through Systems Manager now) =="
  aws ec2 revoke-security-group-ingress --group-id $WEBSG --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null && echo "  port 22 closed" || echo "  port 22 already closed"
  echo "== Remove the old database rule that allowed the whole VPC =="
  aws ec2 revoke-security-group-ingress --group-id sg-0902d4d55a72ab20d --protocol tcp --port 3306 --cidr 10.0.0.0/16 2>/dev/null || true
  echo "== Route 53 checks the whole path: web -> microservices -> database =="
  aws route53 update-health-check --health-check-id $HC --resource-path /health/deep --query HealthCheck.HealthCheckConfig.ResourcePath --output text
  echo LOCKDOWN_DONE ;;

status|*)
  echo "== Tiers =="; aws ec2 describe-instances --filters Name=tag:Project,Values=SecureBank Name=instance-state-name,Values=running,stopped,pending \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name,Placement.AvailabilityZone,PrivateIpAddress,PublicIpAddress||`-`]' --output table
  for T in ${TGUSERS:-} ${TGACCOUNTS:-} ${TGPASSBOOK:-}; do echo "$(basename $(dirname $T)): $(aws elbv2 describe-target-health --target-group-arn $T --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"; done
  aws rds describe-db-instances --db-instance-identifier securebank-db \
    --query 'DBInstances[0].{status:DBInstanceStatus,public:PubliclyAccessible,multiAZ:MultiAZ,az:AvailabilityZone,vpc:DBSubnetGroup.VpcId}' --output table ;;
esac
