#!/bin/bash
# One-time disaster-recovery setup. Run in CloudShell: bash ~/sbrepo/infra/06-dr-setup.sh
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
B=securebank-backups-akshata-2026; DR=securebank-dr-backup-akshata-2026; SITE=securebank-site-akshata-2026
D=securebank-akshata.com

echo "== 1. Backfill: copy backups made before replication was switched on =="
aws s3 sync s3://$B/transactions/ s3://$DR/transactions/ --exclude '*' --include '*.json' --only-show-errors
echo "DR bucket now holds $(aws s3 ls s3://$DR/transactions/ --recursive | grep -c '\.json$') transaction backups"

echo "== 2. Faster Route 53 health check (every 10 s, 2 failures) =="
NEWHC=$(aws route53 create-health-check --caller-reference sbhc-fast-$(date +%s) \
  --health-check-config "Type=HTTP,FullyQualifiedDomainName=$ALBDNS,Port=80,ResourcePath=/health,RequestInterval=10,FailureThreshold=2" \
  --query HealthCheck.Id --output text)
aws route53 change-tags-for-resource --resource-type healthcheck --resource-id $NEWHC --add-tags Key=Name,Value=securebank-alb-health-fast Key=Project,Value=SecureBank
cat > /tmp/r53-fast.json <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"app.$D","Type":"CNAME","SetIdentifier":"primary-alb","Failover":"PRIMARY",
 "HealthCheckId":"$NEWHC","TTL":60,"ResourceRecords":[{"Value":"$ALBDNS"}]}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id $HZ --change-batch file:///tmp/r53-fast.json >/dev/null
OLDHC=$HC
sed -i "s/^HC=.*/HC=$NEWHC/" ~/securebank-vpc.env
aws route53 delete-health-check --health-check-id $OLDHC && echo "replaced health check $OLDHC with $NEWHC"

echo "== 3. Service status page on the S3 failover site =="
aws s3 cp s3://$SITE/index.html s3://$SITE/about.html --only-show-errors 2>/dev/null || true
aws s3 cp ~/sbrepo/site/index.html s3://$SITE/index.html --content-type text/html --only-show-errors
echo "status page: http://$SITE.s3-website-ap-southeast-2.amazonaws.com"

echo '{"time":"'$(date -u +%Y-%m-%dT%H:%M:%S+00:00)'","level":"info","text":"DR setup: vault backfilled, 10-second Route 53 health check, status page published"}' | \
  aws s3 cp - s3://$B/dr-events/$(date -u +%Y%m%d-%H%M%S)-setup.json --content-type application/json
echo DR_SETUP_DONE
