"""account-management microservice: balances and transfers.  Paths: /accounts/...

A transfer runs in one database transaction, then a JSON copy goes to the S3
backup bucket (last-resort backup; replication copies mistakes too).
"""
import os
import sys
import json
import uuid
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import boto3  # noqa: E402
from flask import request  # noqa: E402
from common.svc import create_app, db, out  # noqa: E402

app = create_app('account-management', 'accounts')
S3_BUCKET = os.environ.get('S3_BUCKET', 'securebank-backups-akshata-2026')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
s3 = boto3.client('s3', region_name=AWS_REGION)


def backup(txn):
    try:
        ts = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8]
        s3.put_object(Bucket=S3_BUCKET, Key=f"transactions/live/{ts}-{txn['id']}.json",
                      Body=json.dumps(txn, indent=2, default=str), ContentType='application/json')
        return True
    except Exception as e:
        print(f"S3 backup error: {e}")
        return False


def next_txn_id(c):
    # MAX, not COUNT: ids stay unique even after records are deleted or restored
    c.execute("SELECT MAX(CAST(SUBSTRING(id, 4) AS UNSIGNED)) AS m FROM transactions")
    return f"TXN{(c.fetchone()['m'] or 1000) + 1}"


@app.get('/accounts/<username>')
def balance(username):
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute("SELECT username, account, balance FROM users WHERE username=%s", (username,))
            row = c.fetchone()
    finally:
        conn.close()
    return out(row) if row else out({'error': 'not found'}, 404)


@app.post('/accounts/transfer')
def transfer():
    body = request.get_json(silent=True) or {}
    src, dst = str(body.get('from_user', '')), str(body.get('to_user', ''))
    note = str(body.get('note', '')).strip()[:200]
    try:
        amount = int(body.get('amount', 0))
    except (TypeError, ValueError):
        amount = 0
    if amount <= 0:
        return out({'error': 'Enter an amount of at least Rs 1.'}, 400)
    if not dst or dst == src:
        return out({'error': 'Choose who to send the money to.'}, 400)
    conn = db()
    try:
        conn.begin()
        with conn.cursor() as c:
            c.execute("SELECT balance, account FROM users WHERE username=%s FOR UPDATE", (src,))
            sender = c.fetchone()
            c.execute("SELECT account FROM users WHERE username=%s", (dst,))
            receiver = c.fetchone()
            if not sender or not receiver:
                conn.rollback()
                return out({'error': 'Choose who to send the money to.'}, 400)
            if sender['balance'] < amount:
                conn.rollback()
                return out({'error': f"You can send up to Rs {sender['balance']}."}, 400)
            c.execute("UPDATE users SET balance = balance - %s WHERE username=%s", (amount, src))
            c.execute("UPDATE users SET balance = balance + %s WHERE username=%s", (amount, dst))
            txn_id = next_txn_id(c)
            c.execute("""INSERT INTO transactions (id, from_user, to_user, from_account, to_account, amount, note, backed_up)
                         VALUES (%s, %s, %s, %s, %s, %s, %s, FALSE)""",
                      (txn_id, src, dst, sender['account'], receiver['account'], amount, note))
            c.execute("SELECT * FROM transactions WHERE id=%s", (txn_id,))
            txn = c.fetchone()
        conn.commit()
        if backup(txn):
            with conn.cursor() as c:
                c.execute("UPDATE transactions SET backed_up=TRUE WHERE id=%s", (txn_id,))
            txn['backed_up'] = True
        return out({'transaction': txn})
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
