#!/bin/bash
# EC2 user data for the Mumbai warm standby (second AWS account, ap-south-1).
# Fill in the two values below before launching:
#   SYDNEY_ALB  - the Sydney load balancer's DNS name ($ALBDNS in ~/securebank-vpc.env)
#   REPL_TOKEN  - the contents of ~/.sb_repl_token in the Sydney CloudShell (created by deploy.sh)
# The instance role needs read/write on the Mumbai bucket (it keeps the last copy of the feed there).
set -e
SYDNEY_ALB=REPLACE_ME
REPL_TOKEN=REPLACE_ME
MUM=securebank-dr-mumbai-akshata-2026
IMG=ghcr.io/akshata1412/securebank:latest

fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
dnf install -y docker
systemctl enable --now docker

# Local database for the standby; the password is generated here and never leaves the instance
PW=$(openssl rand -hex 16); echo "$PW" > /root/dbpw; chmod 600 /root/dbpw
docker network create sb
docker run -d --name db --restart always --network sb -v sbdata:/var/lib/mysql \
  -e MARIADB_ROOT_PASSWORD="$PW" -e MARIADB_DATABASE=securebank mariadb:11
for i in $(seq 1 40); do docker exec db mariadb -uroot -p"$PW" -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 3; done

docker run -d --name securebank-app --restart always --network sb -p 80:80 \
  -e DB_HOST=db -e DB_USER=root -e DB_PASSWORD="$PW" -e DB_NAME=securebank \
  -e S3_BUCKET=$MUM -e DR_BUCKET=$MUM -e AWS_REGION=ap-south-1 -e SERVER_ID=mumbai-standby-ap-south-1 \
  -e REPL_SOURCE=http://$SYDNEY_ALB/replication.json -e REPL_TOKEN=$REPL_TOKEN \
  -e SECRET_KEY="$(openssl rand -hex 24)" $IMG

# Every 15 s: pull balances and transactions from Sydney and refresh the local database.
# If Sydney is down the pull fails, and the standby keeps serving the last copy it has.
cat > /usr/local/bin/sb-pull.sh <<'SCRIPT'
#!/bin/bash
while true; do
  echo "$(date -u +%FT%TZ) $(docker exec securebank-app python recovery.py sync 2>&1 | tail -1)"
  sleep 15
done
SCRIPT
chmod +x /usr/local/bin/sb-pull.sh
cat > /etc/systemd/system/sb-pull.service <<'UNIT'
[Unit]
Description=SecureBank standby: pull from Sydney and refresh the database
After=docker.service
[Service]
ExecStart=/usr/local/bin/sb-pull.sh
Restart=always
StandardOutput=append:/var/log/sb-pull.log
StandardError=append:/var/log/sb-pull.log
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now sb-pull.service
