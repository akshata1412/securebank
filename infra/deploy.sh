#!/bin/bash
# Deploy the latest images (three tiers) from GitHub Container Registry. Run in CloudShell:
#   bash ~/sbrepo/infra/deploy.sh
# Tier 2: api-a / api-b pull users, accounts, passbook (secrets from SSM Parameter Store).
# Tier 1: web-1 / web-2 pull the web image, pointed at the internal load balancer.
# Kubernetes: the same four images, applied from k8s/securebank.yaml.
# Everything on EC2 goes through AWS Systems Manager, so no SSH port is open on the web or API tiers.
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
GH=ghcr.io/akshata1412
run(){ # "ids" "commands"
  printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' > /tmp/ssm-params.json
  local cid; cid=$(aws ssm send-command --instance-ids $1 --document-name AWS-RunShellScript --parameters file:///tmp/ssm-params.json --query Command.CommandId --output text)
  for i in $1; do
    for n in $(seq 1 90); do st=$(aws ssm get-command-invocation --command-id $cid --instance-id $i --query Status --output text 2>/dev/null || echo Pending)
      case $st in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 4; done
    echo "  $i: $st $(aws ssm get-command-invocation --command-id $cid --instance-id $i --query StandardOutputContent --output text | tail -3 | tr '\n' ' ')"
  done; }

echo "== Tier 2: microservices on api-a and api-b =="
run "$APIA $APIB" "/usr/local/bin/sb-api-deploy"

echo "== Tier 1: web app on web-1 and web-2 =="
run "$WEB1 $WEB2" "set -e
export AWS_DEFAULT_REGION=ap-southeast-2
P(){ aws ssm get-parameter --name \$1 --with-decryption --query Parameter.Value --output text; }
T=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
IID=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" http://169.254.169.254/latest/meta-data/instance-id)
AZ=\$(curl -s -H \"X-aws-ec2-metadata-token: \$T\" http://169.254.169.254/latest/meta-data/placement/availability-zone)
docker pull -q $GH/securebank-web:latest >/dev/null
docker rm -f securebank-app >/dev/null 2>&1 || true
docker run -d --name securebank-app --restart always -p 80:80 -e API_URL=http://$ILBDNS \
  -e INTERNAL_TOKEN=\$(P /securebank/internal-token) -e SECRET_KEY=\$(P /securebank/secret-key) \
  -e SERVER_ID=\"\$IID (\$AZ)\" -e TARGET_GROUP_ARN=$TG -e HEALTH_CHECK_ID=$HC -e AWS_REGION=ap-southeast-2 \
  $GH/securebank-web:latest >/dev/null
sleep 3; curl -s localhost/health/deep | head -c 120"

echo "== Kubernetes: web + 3 microservices =="
rm -f ~/dkey ~/dkey.pub; ssh-keygen -t ed25519 -N '' -f ~/dkey -q
MIP=$(aws ec2 describe-instances --instance-ids $K8SM --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
P(){ aws ssm get-parameter --name $1 --with-decryption --query Parameter.Value --output text; }
aws ec2-instance-connect send-ssh-public-key --instance-id $K8SM --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null
ssh -i ~/dkey -o StrictHostKeyChecking=no -o LogLevel=ERROR ec2-user@$MIP "kubectl create secret generic securebank-db \
  --from-literal=DB_PASSWORD='$(P /securebank/db-password)' --from-literal=SECRET_KEY='$(P /securebank/secret-key)' \
  --from-literal=INTERNAL_TOKEN='$(P /securebank/internal-token)' --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl delete deployment securebank --ignore-not-found >/dev/null
  kubectl apply -f - >/dev/null" < ~/sbrepo/k8s/securebank.yaml
aws ec2-instance-connect send-ssh-public-key --instance-id $K8SM --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null
ssh -i ~/dkey -o StrictHostKeyChecking=no -o LogLevel=ERROR ec2-user@$MIP "kubectl patch configmap securebank-config --type merge -p '{\"data\":{\"TARGET_GROUP_ARN\":\"$TG\",\"HEALTH_CHECK_ID\":\"$HC\"}}' >/dev/null
  kubectl rollout restart deployment >/dev/null
  for d in users accounts passbook securebank-web; do kubectl rollout status deployment/\$d --timeout=240s; done"
rm -f ~/dkey ~/dkey.pub
echo "App:      http://$ALBDNS/infra"
echo "On k8s:   http://$MIP:30081/infra"
echo DEPLOY_DONE
