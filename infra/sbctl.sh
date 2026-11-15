#!/bin/bash
# Usage: bash ~/sbctl.sh stop | start | status   — SecureBank demo resources on/off
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
IDS="$WEB1 $WEB2 $K8SM $K8SW1 $K8SW2"
case "$1" in
 stop)  aws ec2 stop-instances --instance-ids $IDS --query 'StoppingInstances[].InstanceId' --output text
        aws rds stop-db-instance --db-instance-identifier securebank-db --query DBInstance.DBInstanceStatus --output text 2>/dev/null || true ;;
 start) aws rds start-db-instance --db-instance-identifier securebank-db --query DBInstance.DBInstanceStatus --output text 2>/dev/null || true
        aws ec2 start-instances --instance-ids $IDS --query 'StartingInstances[].InstanceId' --output text
        aws ec2 wait instance-running --instance-ids $IDS
        echo "App (ALB):   http://$ALBDNS"
        echo "S3 website:  http://securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com"
        echo "k8s NodePort: http://$(aws ec2 describe-instances --instance-ids $K8SM --query 'Reservations[0].Instances[0].PublicIpAddress' --output text):30080" ;;
 *)     aws ec2 describe-instances --instance-ids $IDS --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name,PublicIpAddress]' --output table
        aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].DBInstanceStatus' --output text ;;
esac
