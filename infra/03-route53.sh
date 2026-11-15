set -e
source ~/securebank-vpc.env
D=securebank-akshata.com
HZ=$(aws route53 list-hosted-zones-by-name --dns-name $D --query 'HostedZones[0].Id' --output text | sed 's#/hostedzone/##')
HC=$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$ALBDNS'].Id | [0]" --output text)
cat > ~/r53-change.json <<EOF
{"Comment":"SecureBank failover routing","Changes":[
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"app.$D","Type":"CNAME","SetIdentifier":"primary-alb","Failover":"PRIMARY","HealthCheckId":"$HC","TTL":60,
  "ResourceRecords":[{"Value":"$ALBDNS"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"app.$D","Type":"CNAME","SetIdentifier":"secondary-s3","Failover":"SECONDARY","TTL":60,
  "ResourceRecords":[{"Value":"securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"www.$D","Type":"CNAME","TTL":300,
  "ResourceRecords":[{"Value":"securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com"}]}}
]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id $HZ --change-batch file://~/r53-change.json --query ChangeInfo.Status --output text
NS=$(aws route53 get-hosted-zone --id $HZ --query 'DelegationSet.NameServers[0]' --output text)
printf 'HZ=%s\nHC=%s\nNS=%s\n' $HZ $HC $NS >> ~/securebank-vpc.env
echo "zone=$HZ healthcheck=$HC nameserver=$NS"
sleep 25
echo "--- dig app.$D @$NS ---"; dig +short app.$D @$NS
aws route53 get-health-check-status --health-check-id $HC --query 'HealthCheckObservations[0:3].[Region,StatusReport.Status]' --output text
echo R53_OK
