#!/bin/bash
# Sydney side of the cross-region database replica (#12). Run in CloudShell after 09-three-tier.sh:
#   bash ~/sbrepo/infra/10-replication-source.sh binlog            # keep binary logs, create the replication user
#   bash ~/sbrepo/infra/10-replication-source.sh relay <mumbai-ip>  # TLS relay on the NAT instance, open only to Mumbai
#   bash ~/sbrepo/infra/10-replication-source.sh show               # values the Mumbai standby needs
# The database stays private. The relay (socat on the NAT instance's Elastic IP) forwards port 3306 to RDS and
# its security group allows only the Mumbai standby's IP. MySQL encrypts the replication stream end to end (TLS).
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
save(){ grep -q "^$1=" ~/securebank-vpc.env && sed -i "s#^$1=.*#$1=$2#" ~/securebank-vpc.env || echo "$1=$2" >> ~/securebank-vpc.env; export $1=$2; }
run(){ # instance "commands" -> output
  printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' > /tmp/ssm-params.json
  local cid; cid=$(aws ssm send-command --instance-ids $1 --document-name AWS-RunShellScript --parameters file:///tmp/ssm-params.json --query Command.CommandId --output text)
  for n in $(seq 1 60); do st=$(aws ssm get-command-invocation --command-id $cid --instance-id $1 --query Status --output text 2>/dev/null || echo Pending)
    case $st in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 3; done
  aws ssm get-command-invocation --command-id $cid --instance-id $1 --query '[StandardOutputContent,StandardErrorContent]' --output text; }
DBHOST=$(aws rds describe-db-instances --db-instance-identifier securebank-db --query 'DBInstances[0].Endpoint.Address' --output text)

case "$1" in
binlog)
  echo "== Keep binary logs for 24 h and create a TLS-only replication user (run through passbook-management on api-a) =="
  aws ssm get-parameter --name /securebank/repl-db-password >/dev/null 2>&1 || \
    aws ssm put-parameter --name /securebank/repl-db-password --type SecureString --value "$(openssl rand -hex 16)" >/dev/null
  run $APIA "export AWS_DEFAULT_REGION=ap-southeast-2
PW=\$(aws ssm get-parameter --name /securebank/repl-db-password --with-decryption --query Parameter.Value --output text)
cat > /tmp/repl.py <<'PY'
import os, sys
sys.path.insert(0, '/app')
from common.svc import db
c = db().cursor()
c.execute(\"CALL mysql.rds_set_configuration('binlog retention hours', 24)\")
pw = os.environ['RPW']
c.execute(\"CREATE USER IF NOT EXISTS 'repl'@'%%' IDENTIFIED BY %s REQUIRE SSL\", (pw,))
c.execute(\"ALTER USER 'repl'@'%%' IDENTIFIED BY %s REQUIRE SSL\", (pw,))
c.execute(\"GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, SHOW VIEW, TRIGGER, EVENT ON *.* TO 'repl'@'%'\")
c.execute(\"SHOW VARIABLES WHERE Variable_name IN ('log_bin', 'binlog_format')\")
print(c.fetchall())
print('replication user ready')
PY
docker cp /tmp/repl.py passbook:/tmp/repl.py
docker exec -e RPW=\"\$PW\" passbook python /tmp/repl.py"
  echo BINLOG_DONE ;;

relay)
  MUMIP=$2; [ -n "$MUMIP" ] || { echo "usage: $0 relay <mumbai-standby-public-ip>"; exit 1; }
  echo "== Elastic IP for the relay (a fixed address for Mumbai to connect to) =="
  EIP=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=securebank-relay-ip --query 'Addresses[0].PublicIp' --output text)
  if [ "$EIP" = None ]; then
    ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
    aws ec2 create-tags --resources $ALLOC --tags Key=Name,Value=securebank-relay-ip Key=Project,Value=SecureBank
    aws ec2 associate-address --instance-id $NAT --allocation-id $ALLOC >/dev/null
    EIP=$(aws ec2 describe-addresses --allocation-ids $ALLOC --query 'Addresses[0].PublicIp' --output text)
  fi
  save RELAYIP $EIP; save MUMIP $MUMIP
  echo "== Firewall: relay accepts 3306 only from Mumbai; the database accepts the relay (the one documented exception) =="
  aws ec2 authorize-security-group-ingress --group-id $NATSG --ip-permissions \
    "IpProtocol=tcp,FromPort=3306,ToPort=3306,IpRanges=[{CidrIp=$MUMIP/32,Description=Mumbai replica}]" >/dev/null 2>&1 || true
  aws ec2 authorize-security-group-ingress --group-id $DBSG --ip-permissions \
    "IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs=[{GroupId=$NATSG,Description=replication relay for Mumbai}]" >/dev/null 2>&1 || true
  echo "== socat relay on the NAT instance (resolves the RDS name on every connection, so it follows a Multi-AZ failover) =="
  run $NAT "dnf install -y socat >/dev/null 2>&1
cat > /etc/systemd/system/sb-relay.service <<UNIT
[Unit]
Description=SecureBank replication relay to RDS (TLS passes through)
After=network-online.target
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:3306,fork,reuseaddr TCP:$DBHOST:3306
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now sb-relay && systemctl is-active sb-relay"
  echo "relay: $EIP:3306 -> $DBHOST (only $MUMIP may connect)"
  echo RELAY_DONE ;;

show)
  echo "RELAYIP=$RELAYIP"
  echo "repl password: aws ssm get-parameter --name /securebank/repl-db-password --with-decryption --query Parameter.Value --output text"
  echo "Sydney health URL for the promotion watcher: http://$ALBDNS/health/deep" ;;
*) sed -n 2,7p "$0" ;;
esac
