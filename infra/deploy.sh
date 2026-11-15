#!/bin/bash
# Deploy the latest image from GitHub Container Registry to both EC2 web servers
# and the k3s cluster. Run in CloudShell:  bash ~/sbrepo/infra/deploy.sh
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
IMG=ghcr.io/akshata1412/securebank:latest
ROLE=SecureBank-EC2-S3-Role

echo "== IAM: read-only permissions for the Infrastructure page =="
cat > /tmp/infra-read.json <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"InfraRead","Effect":"Allow","Action":["route53:GetHealthCheckStatus","elasticloadbalancing:DescribeTargetHealth",
  "ec2:DescribeInstances","cloudtrail:GetTrail","cloudtrail:GetTrailStatus"],"Resource":"*"},
 {"Sid":"BackupRead","Effect":"Allow","Action":["s3:ListBucket","s3:GetObject","s3:GetObjectVersion"],
  "Resource":["arn:aws:s3:::securebank-backups-akshata-2026","arn:aws:s3:::securebank-backups-akshata-2026/*",
              "arn:aws:s3:::securebank-dr-backup-akshata-2026","arn:aws:s3:::securebank-dr-backup-akshata-2026/*"]}]}
JSON
aws iam put-role-policy --role-name $ROLE --policy-name SecureBank-Infra-ReadOnly --policy-document file:///tmp/infra-read.json

echo "== ALB: faster failure detection for the demo =="
aws elbv2 modify-target-group --target-group-arn $TG --health-check-interval-seconds 5 --health-check-timeout-seconds 3 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 >/dev/null
aws elbv2 modify-target-group-attributes --target-group-arn $TG --attributes Key=deregistration_delay.timeout_seconds,Value=5 >/dev/null

[ -f ~/.sb_secret_key ] || openssl rand -hex 24 > ~/.sb_secret_key
# Shared token for the replication feed the Mumbai standby pulls (give the same value to the standby)
[ -f ~/.sb_repl_token ] || openssl rand -hex 24 > ~/.sb_repl_token
rm -f ~/dkey ~/dkey.pub; ssh-keygen -t ed25519 -N '' -f ~/dkey -q
SSHO="-i $HOME/dkey -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
push_key(){ aws ec2-instance-connect send-ssh-public-key --instance-id $1 --instance-os-user ec2-user --ssh-public-key file://~/dkey.pub >/dev/null; }
ip_of(){ aws ec2 describe-instances --instance-ids $1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

for I in $WEB1 $WEB2; do
  echo "== EC2 $I: pull and restart =="
  push_key $I
  # The DB password is read from the copy already on the server; it is never typed or stored here.
  ssh $SSHO ec2-user@$(ip_of $I) "set -e
    DBPW=\$(grep \"'password'\" /opt/securebank/app.py | cut -d\"'\" -f4)
    TOKEN=\$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
    IID=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/instance-id)
    AZ=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/placement/availability-zone)
    sudo docker pull -q $IMG
    sudo docker rm -f securebank-app >/dev/null 2>&1 || true
    sudo docker run -d --name securebank-app --restart always -p 80:80 \
      -e DB_HOST=securebank-db.cdiauaewk6q6.ap-southeast-2.rds.amazonaws.com -e DB_USER=admin -e DB_PASSWORD=\"\$DBPW\" \
      -e SECRET_KEY=$(cat ~/.sb_secret_key) -e REPL_TOKEN=$(cat ~/.sb_repl_token) -e SERVER_ID=\"\$IID (\$AZ)\" \
      -e TARGET_GROUP_ARN=$TG -e HEALTH_CHECK_ID=$HC $IMG >/dev/null
    echo running \$(sudo docker inspect -f '{{.Config.Image}}' securebank-app) on \$IID"
done

echo "== k3s: apply manifest and roll out =="
MIP=$(ip_of $K8SM)
push_key $K8SM
ssh $SSHO ec2-user@$MIP 'kubectl apply -f - >/dev/null' < ~/sbrepo/k8s/securebank.yaml
push_key $K8SM
ssh $SSHO ec2-user@$MIP "kubectl patch configmap securebank-config --type merge -p '{\"data\":{\"TARGET_GROUP_ARN\":\"$TG\",\"HEALTH_CHECK_ID\":\"$HC\"}}' >/dev/null
  kubectl rollout restart deployment/securebank >/dev/null
  kubectl rollout status deployment/securebank --timeout=180s"
rm -f ~/dkey ~/dkey.pub
echo "App:      http://$ALBDNS/infra"
echo "On k8s:   http://$MIP:30081/infra"
echo DEPLOY_DONE
