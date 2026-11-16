#!/bin/bash
# Show what is stored in the private RDS database, without opening it to the internet.
#   bash ~/sbrepo/infra/db-peek.sh
# CloudShell cannot reach the database (it is outside the VPC, and the database firewall only trusts the microservices).
# So this asks api-a, through Systems Manager, to run a READ-ONLY query inside the passbook-management container.
set -e
source ~/securebank-vpc.env; export AWS_DEFAULT_REGION=ap-southeast-2
cat > /tmp/peek.py <<'PY'
import sys; sys.path.insert(0, '/app')
from common.svc import db, DB_CONFIG
c = db().cursor()
c.execute("SELECT VERSION() v, @@hostname h")
r = c.fetchone()
print(f"Database endpoint : {DB_CONFIG['host']}")
print(f"Engine            : MySQL {r['v']}   schema: {DB_CONFIG['database']}")
print("\nTables")
for t in ("users", "transactions"):
    c.execute(f"SELECT COUNT(*) n FROM {t}"); print(f"  {t:<13} {c.fetchone()['n']} rows")
print("\nusers  (passwords are never selected)")
c.execute("SELECT username, name, account, balance FROM users ORDER BY username")
for u in c.fetchall():
    print(f"  {u['username']:<8} {u['name']:<18} acct {u['account']:<12} Rs {u['balance']:>8,}")
print("\nLatest 5 transactions")
c.execute("SELECT id, from_user, to_user, amount, note, timestamp FROM transactions ORDER BY timestamp DESC LIMIT 5")
for t in c.fetchall():
    print(f"  {t['id']:<10} {t['timestamp']}  {t['from_user']:>7} -> {t['to_user']:<7} Rs {t['amount']:>6,}  {t['note'] or ''}")
PY
B64=$(base64 -w0 /tmp/peek.py)
printf '%s' "echo $B64 | base64 -d > /tmp/peek.py && docker cp /tmp/peek.py passbook:/tmp/peek.py && docker exec passbook python /tmp/peek.py" |
  python3 -c 'import json,sys; print(json.dumps({"commands": [sys.stdin.read()]}))' > /tmp/peek-params.json
CID=$(aws ssm send-command --instance-ids $APIA --document-name AWS-RunShellScript --comment "SecureBank read-only database peek" \
  --parameters file:///tmp/peek-params.json --query Command.CommandId --output text)
for i in $(seq 1 30); do
  S=$(aws ssm get-command-invocation --command-id $CID --instance-id $APIA --query Status --output text 2>/dev/null || echo Pending)
  case $S in Success|Failed|Cancelled|TimedOut) break;; esac; sleep 2; done
aws ssm get-command-invocation --command-id $CID --instance-id $APIA --query StandardOutputContent --output text
ERR=$(aws ssm get-command-invocation --command-id $CID --instance-id $APIA --query StandardErrorContent --output text)
[ -z "$ERR" ] || [ "$ERR" = None ] || echo "error: $ERR"
