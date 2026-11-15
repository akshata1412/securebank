#!/bin/bash
# Usage: bash ~/sbrepo/infra/sbctl.sh stop | start | status   — turn the Sydney side of SecureBank off/on
# stop:  marks the shutdown as planned (the load balancer answers /maintenance), so the Mumbai watcher does NOT promote
#        its replica, then stops every server and the database.
# start: database and NAT first (the private tiers need them), then the servers; removes the maintenance answer last.
# Load balancers and the WAF cannot be stopped; they bill hourly while they exist.
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
SERVERS="$WEB1 $WEB2 $APIA $APIB $K8SM $K8SW1 $K8SW2"
LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn $ALB --query 'Listeners[?Port==`80`].ListenerArn|[0]' --output text)
rule(){ aws elbv2 describe-rules --listener-arn $LISTENER \
  --query "Rules[?Conditions[?Values[0]=='/maintenance']].RuleArn|[0]" --output text; }
case "$1" in
 stop)
  echo "== Planned shutdown: tell the Mumbai watcher not to promote =="
  [ "$(rule)" = None ] && aws elbv2 create-rule --listener-arn $LISTENER --priority 5 \
    --conditions Field=path-pattern,Values=/maintenance \
    --actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"200","ContentType":"text/plain","MessageBody":"planned shutdown"}}]' >/dev/null
  echo "== Stopping servers, NAT instance and database =="
  aws ec2 stop-instances --instance-ids $SERVERS $NAT --query 'StoppingInstances[].InstanceId' --output text
  aws rds stop-db-instance --db-instance-identifier securebank-db --query DBInstance.DBInstanceStatus --output text 2>/dev/null || true
  echo "Stopped. Route 53 now sends visitors to Mumbai (read-only). RDS restarts by itself after 7 days if left stopped." ;;
 start)
  echo "== Database and NAT instance first =="
  aws rds start-db-instance --db-instance-identifier securebank-db --query DBInstance.DBInstanceStatus --output text 2>/dev/null || true
  aws ec2 start-instances --instance-ids $NAT >/dev/null; aws ec2 wait instance-running --instance-ids $NAT
  echo "== Servers =="
  aws ec2 start-instances --instance-ids $SERVERS --query 'StartingInstances[].InstanceId' --output text
  aws ec2 wait instance-running --instance-ids $SERVERS
  echo "== Waiting for the database (5-10 min) =="
  aws rds wait db-instance-available --db-instance-identifier securebank-db
  echo "== Waiting for the app's deep health check =="
  for i in $(seq 1 40); do curl -sf -m 5 http://$ALBDNS/health/deep >/dev/null && break; sleep 10; done
  R=$(rule); [ "$R" != None ] && aws elbv2 delete-rule --rule-arn $R
  echo "App:          http://app.securebank-akshata.com  (load balancer: http://$ALBDNS)"
  echo "Kubernetes:   http://$(aws ec2 describe-instances --instance-ids $K8SM --query 'Reservations[0].Instances[0].PublicIpAddress' --output text):30081"
  echo "Static page:  http://securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com" ;;
 *)
  aws ec2 describe-instances --instance-ids $SERVERS $NAT --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name]' --output table
  echo "database: $(aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].DBInstanceStatus' --output text)"
  echo "planned-shutdown flag: $([ "$(rule)" = None ] && echo off || echo ON)"
  curl -s -m 5 http://$ALBDNS/health/deep | head -c 160; echo ;;
esac
