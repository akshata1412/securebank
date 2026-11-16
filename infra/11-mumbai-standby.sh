#!/bin/bash
# Mumbai standby region (second AWS account, ap-south-1). Runs ON the standby server (securebank-mumbai-standby)
# as root, through Systems Manager Run Command:
#   bash 11-mumbai-standby.sh eip                                   # fixed public IP (Sydney's relay allows only this)
#   bash 11-mumbai-standby.sh replica <relay-ip> <repl-password>    # MySQL 8.4 replica of the Sydney database (#12)
#   bash 11-mumbai-standby.sh stack <sydney-alb-dns>                # 2 web + 3 microservices, internal + public LB (#13)
#   bash 11-mumbai-standby.sh promote                               # make the replica the writable primary
#   bash 11-mumbai-standby.sh status
# The promotion watcher (installed by "stack") promotes the replica by itself when Sydney's deep health check
# has failed for 60 seconds.
set -e
export AWS_DEFAULT_REGION=ap-south-1
ENVF=/root/sb-mumbai.env; touch $ENVF; chmod 600 $ENVF; source $ENVF
GH=ghcr.io/akshata1412
save(){ grep -q "^$1=" $ENVF && sed -i "s#^$1=.*#$1=$2#" $ENVF || echo "$1=$2" >> $ENVF; export $1=$2; }
md(){ T=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
      curl -s -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/$1; }
SELF=$(md instance-id); MYIP=$(md local-ipv4)
q(){ docker exec replica mysql -uroot -p"$ROOTPW" -N -e "$1" 2>/dev/null; }

case "$1" in
eip)
  E=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=securebank-mumbai-ip --query 'Addresses[0].PublicIp' --output text)
  if [ "$E" = None ]; then
    A=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
    aws ec2 create-tags --resources $A --tags Key=Name,Value=securebank-mumbai-ip
    aws ec2 associate-address --instance-id $SELF --allocation-id $A >/dev/null
    E=$(aws ec2 describe-addresses --allocation-ids $A --query 'Addresses[0].PublicIp' --output text)
  fi
  save MUMIP $E; echo "Mumbai standby public IP: $E"; echo EIP_DONE ;;

replica)
  RELAY=$2; RPW=$3; [ -n "$RELAY" ] && [ -n "$RPW" ] || { echo "usage: $0 replica <relay-ip> <repl-password>"; exit 1; }
  save RELAY $RELAY; save RPW $RPW
  [ -n "$ROOTPW" ] || save ROOTPW $(openssl rand -hex 16)
  [ -n "$APPPW" ] || save APPPW $(openssl rand -hex 16)
  echo "== Retire the old standby (MariaDB + app-level feed) =="
  systemctl disable --now sb-pull.service 2>/dev/null || true
  docker rm -f securebank-app db >/dev/null 2>&1 || true
  docker network create sb >/dev/null 2>&1 || true
  echo "== MySQL 8.4 replica (small memory settings for a 1 GB server) =="
  docker rm -f replica >/dev/null 2>&1 || true; docker volume rm replicadata >/dev/null 2>&1 || true
  # replicate-do-db: copy only SecureBank data, not RDS's own mysql.rds_* housekeeping tables
  docker run -d --name replica --restart always --network sb -p 3306:3306 -v replicadata:/var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD="$ROOTPW" mysql:8.4 --server-id=2 --relay-log=relay-bin --skip-replica-start=OFF \
    --innodb-buffer-pool-size=64M --performance-schema=OFF --max-connections=60 --log-replica-updates=ON \
    --replicate-do-db=securebank >/dev/null
  for i in $(seq 1 60); do q "SELECT 1" >/dev/null && break; sleep 3; done
  echo "== Note the source position, then copy the data over the encrypted link =="
  M="docker run --rm --network host mysql:8.4"
  POS=$($M mysql -h $RELAY -u repl -p"$RPW" --ssl-mode=REQUIRED -N -e "SHOW BINARY LOG STATUS" 2>/dev/null | head -1)
  FILE=$(echo "$POS" | awk '{print $1}'); OFF=$(echo "$POS" | awk '{print $2}')
  [ -n "$FILE" ] || { echo "cannot reach the source through the relay $RELAY"; exit 1; }
  echo "source position: $FILE $OFF"
  $M mysqldump -h $RELAY -u repl -p"$RPW" --ssl-mode=REQUIRED --single-transaction --set-gtid-purged=OFF --no-tablespaces \
    --databases securebank 2>/dev/null | docker exec -i replica mysql -uroot -p"$ROOTPW" 2>/dev/null
  echo "copied: $(q 'SELECT COUNT(*) FROM securebank.users') customers, $(q 'SELECT COUNT(*) FROM securebank.transactions') transactions"
  echo "== Start replicating, then lock the replica read-only =="
  q "CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY '$APPPW'; GRANT SELECT, INSERT, UPDATE, DELETE ON securebank.* TO 'app'@'%';"
  q "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$RELAY', SOURCE_PORT=3306, SOURCE_USER='repl', SOURCE_PASSWORD='$RPW',
     SOURCE_LOG_FILE='$FILE', SOURCE_LOG_POS=$OFF, SOURCE_SSL=1, GET_SOURCE_PUBLIC_KEY=1,
     SOURCE_RETRY_COUNT=100000, SOURCE_CONNECT_RETRY=60; START REPLICA;
     SET PERSIST read_only=ON; SET PERSIST super_read_only=ON;"
  sleep 5
  docker exec replica mysql -uroot -p"$ROOTPW" -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E 'Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind_Source|Last_.*Error:' | grep -v ': $'
  echo REPLICA_DONE ;;

stack)
  SYD=$2; [ -n "$SYD" ] || { echo "usage: $0 stack <sydney-alb-dns>"; exit 1; }
  save SYDHEALTH "http://$SYD/health/deep"
  [ -n "$TOKEN" ] || save TOKEN $(openssl rand -hex 24)
  [ -n "$WEBKEY" ] || save WEBKEY $(openssl rand -hex 24)
  VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  MYAZ=$(md placement/availability-zone)
  SUBA=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=availability-zone,Values=$MYAZ --query 'Subnets[0].SubnetId' --output text)
  OTHERAZ=ap-south-1a; [ "$MYAZ" = ap-south-1a ] && OTHERAZ=ap-south-1b   # t2.micro is not offered in ap-south-1c
  SUBB=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=availability-zone,Values=$OTHERAZ --query 'Subnets[0].SubnetId' --output text)
  echo "== Firewall per tier (security groups) =="
  sg(){ local id; id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$1 Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
        [ "$id" = None ] && id=$(aws ec2 create-security-group --group-name $1 --description "$2" --vpc-id $VPC --query GroupId --output text); echo $id; }
  allow(){ aws ec2 authorize-security-group-ingress --group-id $1 --ip-permissions "$2" >/dev/null 2>&1 || true; }
  ALBSG=$(sg mb-alb-sg "Mumbai public load balancer - HTTP from the internet")
  WEBSG=$(sg mb-web-sg "Mumbai web tier - HTTP from the public load balancer only")
  ILBSG=$(sg mb-ilb-sg "Mumbai internal load balancer - HTTP from the web tier only")
  APISG=$(sg mb-api-sg "Mumbai microservices - 5001-5003 from the internal load balancer only")
  DBSG=$(sg mb-db-sg "Mumbai replica database - MySQL from the microservices only")
  allow $ALBSG "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]"
  allow $WEBSG "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$ALBSG}]"
  allow $ILBSG "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=$WEBSG}]"
  allow $APISG "IpProtocol=tcp,FromPort=5001,ToPort=5003,UserIdGroupPairs=[{GroupId=$ILBSG}]"
  allow $DBSG "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$APISG}]"
  echo "== Internal load balancer with the same path rules as Sydney =="
  lb(){ local a; a=$(aws elbv2 describe-load-balancers --names $1 --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
        [ -z "$a" ] || [ "$a" = None ] && a=$(aws elbv2 create-load-balancer --name $1 --scheme $2 --type application --subnets $SUBA $SUBB \
          --security-groups $3 --query 'LoadBalancers[0].LoadBalancerArn' --output text); echo $a; }
  tg(){ local a; a=$(aws elbv2 describe-target-groups --names $1 --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
        [ -z "$a" ] || [ "$a" = None ] && a=$(aws elbv2 create-target-group --name $1 --protocol HTTP --port $2 --vpc-id $VPC --health-check-path /health \
          --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text); echo $a; }
  ILB=$(lb mb-internal-alb internal $ILBSG); save MILBDNS $(aws elbv2 describe-load-balancers --load-balancer-arns $ILB --query 'LoadBalancers[0].DNSName' --output text)
  TU=$(tg mb-users 5001); TA=$(tg mb-accounts 5002); TP=$(tg mb-passbook 5003); TW=$(tg mb-web 80)
  if [ "$(aws elbv2 describe-listeners --load-balancer-arn $ILB --query 'length(Listeners)' --output text)" = 0 ]; then
    L=$(aws elbv2 create-listener --load-balancer-arn $ILB --protocol HTTP --port 80 \
        --default-actions '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"404","ContentType":"text/plain","MessageBody":"no such service"}}]' \
        --query 'Listeners[0].ListenerArn' --output text)
    aws elbv2 create-rule --listener-arn $L --priority 10 --conditions Field=path-pattern,Values=/users,/users/* --actions Type=forward,TargetGroupArn=$TU >/dev/null
    aws elbv2 create-rule --listener-arn $L --priority 20 --conditions Field=path-pattern,Values=/accounts,/accounts/* --actions Type=forward,TargetGroupArn=$TA >/dev/null
    aws elbv2 create-rule --listener-arn $L --priority 30 --conditions Field=path-pattern,Values=/passbook,/passbook/* --actions Type=forward,TargetGroupArn=$TP >/dev/null
  fi
  echo "== Public load balancer =="
  PLB=$(lb mb-public-alb internet-facing $ALBSG); save MALBDNS $(aws elbv2 describe-load-balancers --load-balancer-arns $PLB --query 'LoadBalancers[0].DNSName' --output text)
  [ "$(aws elbv2 describe-listeners --load-balancer-arn $PLB --query 'length(Listeners)' --output text)" = 0 ] && \
    aws elbv2 create-listener --load-balancer-arn $PLB --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TW >/dev/null
  echo "== This server (AZ $MYAZ): replica + 3 microservices + web =="
  ENIS=$(aws ec2 describe-instances --instance-ids $SELF --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
  aws ec2 modify-network-interface-attribute --network-interface-id $ENIS --groups $WEBSG $APISG $DBSG
  cat > /usr/local/bin/sb-mumbai-apps <<APPS
#!/bin/bash
# (Re)start the Mumbai web + microservice containers. DB_HOST is the replica on securebank-mumbai-standby.
DBH=\${1:-$MYIP}; NAME=\$(hostname -s)
port=5001
for s in users accounts passbook; do
  docker pull -q $GH/securebank-\$s:latest >/dev/null; docker rm -f \$s >/dev/null 2>&1 || true
  docker run -d --name \$s --restart always -p \$port:5000 -e DB_HOST=\$DBH -e DB_USER=app -e DB_PASSWORD=$APPPW \
    -e INTERNAL_TOKEN=$TOKEN -e S3_BUCKET=securebank-dr-mumbai-akshata-2026 -e DR_BUCKET=securebank-dr-mumbai-akshata-2026 \
    -e AWS_REGION=ap-south-1 -e SERVER_ID="mumbai \$NAME" -e GUNICORN_CMD_ARGS="--workers 1" $GH/securebank-\$s:latest >/dev/null
  port=\$((port+1))
done
docker pull -q $GH/securebank-web:latest >/dev/null; docker rm -f web securebank-app >/dev/null 2>&1 || true
docker run -d --name web --restart always -p 80:80 -e API_URL=http://$MILBDNS -e INTERNAL_TOKEN=$TOKEN -e SECRET_KEY=$WEBKEY \
  -e AWS_REGION=ap-south-1 -e TARGET_GROUP_ARN=$TW -e S3_BUCKET=securebank-dr-mumbai-akshata-2026 -e DR_BUCKET=securebank-dr-mumbai-akshata-2026 -e SERVER_ID="mumbai \$NAME" -e GUNICORN_CMD_ARGS="--workers 1" $GH/securebank-web:latest >/dev/null
echo "apps running, database at \$DBH"
APPS
  chmod +x /usr/local/bin/sb-mumbai-apps; /usr/local/bin/sb-mumbai-apps $MYIP
  echo "== Second server in the other AZ: web + 3 microservices =="
  B=$(aws ec2 describe-instances --filters Name=tag:Name,Values=securebank-mumbai-standby-b Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[0].Instances[0].InstanceId' --output text)
  if [ "$B" = None ]; then
    PROFILE=$(aws ec2 describe-instances --instance-ids $SELF --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
    AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
    { echo '#!/bin/bash'; echo 'fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile'
      echo 'dnf install -y docker && systemctl enable --now docker'; cat /usr/local/bin/sb-mumbai-apps | sed 1d > /tmp/apps-body
      echo 'cat > /usr/local/bin/sb-mumbai-apps <<"APPS"'; cat /usr/local/bin/sb-mumbai-apps; echo 'APPS'
      echo 'chmod +x /usr/local/bin/sb-mumbai-apps; /usr/local/bin/sb-mumbai-apps'; } > /tmp/b-userdata.sh
    B=$(aws ec2 run-instances --image-id $AMI --instance-type t2.micro --subnet-id $SUBB --security-group-ids $WEBSG $APISG \
        --iam-instance-profile Arn=$PROFILE --user-data file:///tmp/b-userdata.sh --credit-specification CpuCredits=standard \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=securebank-mumbai-standby-b}]" --query 'Instances[0].InstanceId' --output text)
    aws ec2 wait instance-running --instance-ids $B
  fi
  save STANDBYB $B
  for P in "$TU 5001" "$TA 5002" "$TP 5003" "$TW 80"; do set -- $P
    aws elbv2 register-targets --target-group-arn $1 --targets Id=$SELF,Port=$2 Id=$B,Port=$2; done
  echo "== Promotion watcher: promote the replica if Sydney's deep health check fails for 60 s =="
  cp "$0" /usr/local/bin/sb-mumbai; chmod +x /usr/local/bin/sb-mumbai
  cat > /usr/local/bin/sb-watch <<'W'
#!/bin/bash
source /root/sb-mumbai.env; FAILS=0
while true; do
  # A planned shutdown (sbctl.sh stop) makes Sydney's load balancer answer /maintenance: not a disaster, don't promote.
  if curl -sf -m 5 "$SYDHEALTH" >/dev/null; then FAILS=0
  elif curl -s -m 5 "${SYDHEALTH%/health/deep}/maintenance" | grep -q planned; then FAILS=0
  else FAILS=$((FAILS+1)); fi
  RUNNING=$(docker exec replica mysql -uroot -p"$ROOTPW" -N -e "SELECT SERVICE_STATE FROM performance_schema.replication_connection_status" 2>/dev/null)
  if [ $FAILS -ge 6 ] && [ -n "$RUNNING" ]; then echo "$(date -u +%FT%TZ) Sydney down for 60 s: promoting"; /usr/local/bin/sb-mumbai promote; fi
  sleep 10
done
W
  chmod +x /usr/local/bin/sb-watch
  printf '[Unit]\nDescription=SecureBank promotion watcher\nAfter=docker.service\n[Service]\nExecStart=/usr/local/bin/sb-watch\nRestart=always\nStandardOutput=append:/var/log/sb-watch.log\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/sb-watch.service
  systemctl daemon-reload && systemctl enable --now sb-watch
  echo "Mumbai public load balancer: $MALBDNS"
  echo STACK_DONE ;;

promote)
  docker exec replica mysql -uroot -p"$ROOTPW" -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF;" 2>/dev/null
  echo "$(date -u +%FT%TZ) replica promoted: Mumbai is now the writable primary"
  echo PROMOTE_DONE ;;

status|*)
  echo "== Replica =="; docker exec replica mysql -uroot -p"$ROOTPW" -e "SHOW REPLICA STATUS\G" 2>/dev/null | grep -E 'Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind_Source|Last_.*Error:' | grep -v ': $' || echo "not replicating (promoted or not set up)"
  echo "read_only=$(q 'SELECT @@super_read_only')  customers=$(q 'SELECT COUNT(*) FROM securebank.users')  transactions=$(q 'SELECT COUNT(*) FROM securebank.transactions')"
  echo "== Containers =="; docker ps --format '{{.Names}} {{.Status}}'
  echo "== Watcher =="; tail -3 /var/log/sb-watch.log 2>/dev/null; echo "public LB: ${MALBDNS:-not created}" ;;
esac
