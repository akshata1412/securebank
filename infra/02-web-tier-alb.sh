set -e
export AWS_DEFAULT_REGION=ap-southeast-2
source ~/securebank-vpc.env
DEFVPC=vpc-0e6188cb357c1e99a; RDSSG=sg-0902d4d55a72ab20d
# --- VPC peering so the new web tier can reach RDS in the default VPC ---
PCX=$(aws ec2 create-vpc-peering-connection --vpc-id $VPC --peer-vpc-id $DEFVPC --query VpcPeeringConnection.VpcPeeringConnectionId --output text)
aws ec2 create-tags --resources $PCX --tags Key=Name,Value=securebank-to-default-pcx Key=Project,Value=SecureBank
sleep 5
aws ec2 accept-vpc-peering-connection --vpc-peering-connection-id $PCX >/dev/null
sleep 5
aws ec2 modify-vpc-peering-connection-options --vpc-peering-connection-id $PCX --requester-peering-connection-options AllowDnsResolutionFromRemoteVpc=true --accepter-peering-connection-options AllowDnsResolutionFromRemoteVpc=true >/dev/null || echo "dns-option skipped"
for RT in $PUBRT $PRIRT; do aws ec2 create-route --route-table-id $RT --destination-cidr-block 172.31.0.0/16 --vpc-peering-connection-id $PCX >/dev/null; done
for RT in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$DEFVPC --query 'RouteTables[].RouteTableId' --output text); do aws ec2 create-route --route-table-id $RT --destination-cidr-block 10.0.0.0/16 --vpc-peering-connection-id $PCX >/dev/null; done
aws ec2 authorize-security-group-ingress --group-id $RDSSG --ip-permissions 'IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=10.0.0.0/16,Description=SecureBank VPC web tier}]' >/dev/null || true
echo "PCX=$PCX" >> ~/securebank-vpc.env
# --- user data for both web servers ---
cat > ~/web-userdata.sh <<'EOF'
#!/bin/bash
dnf install -y docker
systemctl enable --now docker
mkdir -p /opt/securebank && aws s3 cp s3://securebank-backups-akshata-2026/code/ /opt/securebank/ --recursive --region ap-southeast-2
cd /opt/securebank
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
docker build -t securebank:v1.0 .
docker run -d --name securebank-app --restart always -p 80:80 -e SERVER_ID="$IID ($AZ)" securebank:v1.0
EOF
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
launch(){ aws ec2 run-instances --image-id $AMI --instance-type t3.micro --subnet-id $1 --security-group-ids $WEBSG --key-name securebank-key --iam-instance-profile Name=SecureBank-EC2-S3-Role --user-data file://~/web-userdata.sh --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$2},{Key=Project,Value=SecureBank}]" --query 'Instances[0].InstanceId' --output text; }
WEB1=$(launch $PUBA securebank-web-1); WEB2=$(launch $PUBB securebank-web-2)
echo "WEB1=$WEB1" >> ~/securebank-vpc.env; echo "WEB2=$WEB2" >> ~/securebank-vpc.env
# --- Application Load Balancer ---
ALB=$(aws elbv2 create-load-balancer --name securebank-alb --subnets $PUBA $PUBB --security-groups $ALBSG --scheme internet-facing --type application --tags Key=Project,Value=SecureBank --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG=$(aws elbv2 create-target-group --name securebank-tg --protocol HTTP --port 80 --vpc-id $VPC --health-check-path / --health-check-interval-seconds 15 --healthy-threshold-count 2 --matcher HttpCode=200-399 --query 'TargetGroups[0].TargetGroupArn' --output text)
aws ec2 wait instance-running --instance-ids $WEB1 $WEB2
aws elbv2 register-targets --target-group-arn $TG --targets Id=$WEB1 Id=$WEB2
aws elbv2 create-listener --load-balancer-arn $ALB --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG >/dev/null
DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB --query 'LoadBalancers[0].DNSName' --output text)
echo "ALB=$ALB" >> ~/securebank-vpc.env; echo "TG=$TG" >> ~/securebank-vpc.env; echo "ALBDNS=$DNS" >> ~/securebank-vpc.env
echo "ALB DNS: http://$DNS"
echo WEB_OK
