#!/bin/bash
# Three-level DNS failover (#14). Run in the Sydney CloudShell after the Mumbai stack exists:
#   bash ~/sbrepo/infra/12-route53-three-level.sh <mumbai-public-alb-dns>
# app.securebank-akshata.com    PRIMARY   -> Sydney public load balancer   (health check: /health/deep)
#                               SECONDARY -> mumbai.securebank-akshata.com
# mumbai.securebank-akshata.com PRIMARY   -> Mumbai public load balancer   (health check: /health/deep)
#                               SECONDARY -> S3 static page "We'll be back soon"
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
MALB=$1; [ -n "$MALB" ] || { echo "usage: $0 <mumbai-public-alb-dns>"; exit 1; }
D=securebank-akshata.com
S3SITE=securebank-site-akshata-2026.s3-website-ap-southeast-2.amazonaws.com
HC2=$(aws route53 list-health-checks --query "HealthChecks[?HealthCheckConfig.FullyQualifiedDomainName=='$MALB'].Id | [0]" --output text)
if [ "$HC2" = None ]; then
  HC2=$(aws route53 create-health-check --caller-reference mumbai-$(date +%s) --health-check-config \
    "Type=HTTP,FullyQualifiedDomainName=$MALB,Port=80,ResourcePath=/health/deep,RequestInterval=10,FailureThreshold=2" \
    --query HealthCheck.Id --output text)
  aws route53 change-tags-for-resource --resource-type healthcheck --resource-id $HC2 --add-tags Key=Name,Value=securebank-mumbai-alb
fi
echo "HC2=$HC2" >> ~/securebank-vpc.env
cat > /tmp/r53-3level.json <<JSON
{"Comment":"SecureBank: Sydney -> Mumbai -> static page","Changes":[
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"mumbai.$D","Type":"CNAME","SetIdentifier":"mumbai-primary","Failover":"PRIMARY",
  "HealthCheckId":"$HC2","TTL":60,"ResourceRecords":[{"Value":"$MALB"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"mumbai.$D","Type":"CNAME","SetIdentifier":"static-page","Failover":"SECONDARY",
  "TTL":60,"ResourceRecords":[{"Value":"$S3SITE"}]}},
 {"Action":"UPSERT","ResourceRecordSet":{"Name":"app.$D","Type":"CNAME","SetIdentifier":"secondary-s3","Failover":"SECONDARY",
  "TTL":60,"ResourceRecords":[{"Value":"mumbai.$D"}]}}]}
JSON
aws route53 change-resource-record-sets --hosted-zone-id $HZ --change-batch file:///tmp/r53-3level.json --query ChangeInfo.Status --output text
sed -i '/^MUMDNS=/d' ~/securebank-vpc.env; echo "MUMDNS=$MALB" >> ~/securebank-vpc.env
echo "app.$D: Sydney ($ALBDNS) -> mumbai.$D -> Mumbai ($MALB) -> S3 static page"
echo ROUTE53_DONE
