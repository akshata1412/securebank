#!/bin/bash
# Point the Route 53 failover SECONDARY at the Mumbai standby. Run in the Sydney account's CloudShell:
#   bash ~/sbrepo/infra/08-route53-mumbai.sh <mumbai-public-dns>
set -e
source ~/securebank-vpc.env
MUMDNS=$1; [ -n "$MUMDNS" ] || { echo "usage: $0 <mumbai-public-dns>"; exit 1; }
cat > /tmp/r53-mumbai.json <<JSON
{"Comment":"SecureBank cross-region failover","Changes":[{"Action":"UPSERT","ResourceRecordSet":{
 "Name":"app.securebank-akshata.com","Type":"CNAME","SetIdentifier":"secondary-s3","Failover":"SECONDARY",
 "TTL":60,"ResourceRecords":[{"Value":"$MUMDNS"}]}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id $HZ --change-batch file:///tmp/r53-mumbai.json --query ChangeInfo.Status --output text
echo "MUMDNS=$MUMDNS" >> ~/securebank-vpc.env
echo "Failover now: Sydney load balancer (primary) -> Mumbai standby $MUMDNS (secondary)"
