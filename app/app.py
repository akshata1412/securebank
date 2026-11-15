"""SecureBank - a cloud-native banking app on AWS.

Data lives in Amazon RDS (MySQL); every transfer is also written to S3 and
replicated to a disaster-recovery bucket. Config comes from environment
variables so the same image runs on EC2 and on Kubernetes.
"""
import os
import json
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3
import pymysql
from flask import Flask, render_template, request, redirect, url_for, session, jsonify

import infra
import recovery

app = Flask(__name__)
# Same key on every server so login sessions work behind the load balancer
app.secret_key = os.environ.get('SECRET_KEY', 'change-me')

SERVER_ID = os.environ.get('SERVER_ID', os.environ.get('HOSTNAME', 'local'))
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
S3_BUCKET = os.environ.get('S3_BUCKET', 'securebank-backups-akshata-2026')
IST = timezone(timedelta(hours=5, minutes=30))

DB_CONFIG = {
    'host': os.environ.get('DB_HOST', 'localhost'),
    'user': os.environ.get('DB_USER', 'admin'),
    'password': os.environ.get('DB_PASSWORD', ''),
    'database': os.environ.get('DB_NAME', 'securebank'),
    'port': int(os.environ.get('DB_PORT', '3306')),
    'cursorclass': pymysql.cursors.DictCursor,
    'autocommit': True,
    'connect_timeout': 5,
}

s3 = boto3.client('s3', region_name=AWS_REGION)


def db():
    return pymysql.connect(**DB_CONFIG)


# ============ FORMATTING ============

def inr(n):
    """Indian digit grouping: 150000 -> 1,50,000."""
    n = int(n or 0)
    s = str(abs(n))
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        groups = []
        while len(head) > 2:
            groups.insert(0, head[-2:])
            head = head[:-2]
        if head:
            groups.insert(0, head)
        s = ','.join(groups) + ',' + tail
    return ('-' if n < 0 else '') + s


def ist(ts, fmt='%d %b %Y, %I:%M %p'):
    """Show a UTC timestamp from the database in Indian time."""
    if not ts:
        return ''
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(IST).strftime(fmt).replace(' 0', ' ')


app.jinja_env.filters['inr'] = inr
app.jinja_env.filters['ist'] = ist


@app.context_processor
def page_globals():
    return {'server_id': SERVER_ID, 'signed_in': 'user' in session}


# ============ DATA ============

def backup(txn):
    """Write the transaction to S3; replication copies it to the DR bucket."""
    try:
        ts = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-') + str(uuid.uuid4())[:8]
        s3.put_object(Bucket=S3_BUCKET, Key=f"transactions/live/{ts}-{txn['id']}.json",
                      Body=json.dumps(txn, indent=2, default=str), ContentType='application/json')
        return True
    except Exception as e:
        print(f"S3 error: {e}")
        return False


def get_user(username):
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute("SELECT * FROM users WHERE username=%s", (username,))
            return c.fetchone()
    finally:
        conn.close()


def get_all_users():
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute("SELECT * FROM users")
            return {row['username']: row for row in c.fetchall()}
    finally:
        conn.close()


def next_txn_id(c):
    # MAX, not COUNT: ids stay unique even after records are deleted or restored
    c.execute("SELECT MAX(CAST(SUBSTRING(id, 4) AS UNSIGNED)) AS m FROM transactions")
    m = c.fetchone()['m']
    return f"TXN{(m or 1000) + 1}"


def do_transfer(from_user, to_user, amount, note):
    conn = db()
    try:
        conn.begin()
        with conn.cursor() as c:
            c.execute("SELECT balance, account FROM users WHERE username=%s FOR UPDATE", (from_user,))
            sender = c.fetchone()
            c.execute("SELECT account FROM users WHERE username=%s", (to_user,))
            receiver = c.fetchone()
            if sender['balance'] < amount:
                conn.rollback()
                return None, "Insufficient balance"
            c.execute("UPDATE users SET balance = balance - %s WHERE username=%s", (amount, from_user))
            c.execute("UPDATE users SET balance = balance + %s WHERE username=%s", (amount, to_user))
            txn_id = next_txn_id(c)
            c.execute("""INSERT INTO transactions (id, from_user, to_user, from_account, to_account, amount, note, backed_up)
                         VALUES (%s, %s, %s, %s, %s, %s, %s, FALSE)""",
                      (txn_id, from_user, to_user, sender['account'], receiver['account'], amount, note))
            c.execute("SELECT * FROM transactions WHERE id=%s", (txn_id,))
            txn = c.fetchone()
        conn.commit()
        if backup(txn):
            with conn.cursor() as c:
                c.execute("UPDATE transactions SET backed_up=TRUE WHERE id=%s", (txn_id,))
            txn['backed_up'] = True
        return txn, None
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def get_user_transactions(username, limit=None):
    conn = db()
    try:
        with conn.cursor() as c:
            sql = """SELECT * FROM transactions WHERE from_user=%s OR to_user=%s
                     ORDER BY timestamp DESC, id DESC"""
            if limit:
                sql += f" LIMIT {int(limit)}"
            c.execute(sql, (username, username))
            return c.fetchall()
    finally:
        conn.close()


def greeting():
    h = datetime.now(IST).hour
    return 'Good morning' if h < 12 else ('Good afternoon' if h < 17 else 'Good evening')


# ============ ROUTES ============

@app.route('/', methods=['GET', 'POST'])
def login():
    if 'user' in session:
        return redirect(url_for('dashboard'))
    error = None
    if request.method == 'POST':
        u = request.form.get('username', '').strip().lower()
        p = request.form.get('password', '')
        try:
            user = get_user(u)
        except Exception:
            user, error = None, "We can't reach the database right now. Try again in a minute."
        if user and user['password'] == p:
            session['user'] = u
            return redirect(url_for('dashboard'))
        error = error or "That username and password don't match. Check both and try again."
    return render_template('login.html', error=error)


@app.route('/dashboard')
def dashboard():
    if 'user' not in session:
        return redirect(url_for('login'))
    user = get_user(session['user'])
    return render_template('dashboard.html', page='dashboard', user=user, users=get_all_users(),
                           entries=get_user_transactions(session['user'], limit=6), greeting=greeting())


@app.route('/transfer', methods=['GET', 'POST'])
def transfer():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    user, users = get_user(cu), get_all_users()
    done = error = None
    if request.method == 'POST':
        r = request.form.get('recipient')
        try:
            a = int(request.form.get('amount', 0))
        except ValueError:
            a = 0
        n = request.form.get('note', '').strip()[:200]
        if r not in users or r == cu:
            error = "Choose who to send the money to."
        elif a <= 0:
            error = "Enter an amount of at least Rs 1."
        elif a > user['balance']:
            error = f"You can send up to Rs {inr(user['balance'])}."
        else:
            txn, err = do_transfer(cu, r, a, n)
            if err:
                error = err
            else:
                done = txn
                user = get_user(cu)
    return render_template('transfer.html', page='transfer', user=user, users=users, current_user=cu,
                           done=done, error=error)


@app.route('/history')
def history():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    return render_template('history.html', page='history', user=get_user(cu), users=get_all_users(),
                           entries=get_user_transactions(cu))


@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


@app.route('/infra')
def infra_page():
    t0 = time.time()
    snap = infra.snapshot(db)
    return render_template('infra.html', page='infra', s=snap, region=AWS_REGION,
                           ms=int((time.time() - t0) * 1000))


@app.route('/infra.json')
def infra_json():
    return jsonify(infra.snapshot(db))


@app.route('/dr')
def dr_page():
    t0 = time.time()
    report = recovery.status(db)
    return render_template('dr.html', page='dr', r=report, ms=int((time.time() - t0) * 1000))


@app.route('/dr.json')
def dr_json():
    return jsonify(recovery.status(db))


@app.route('/replication.json')
def replication():
    """Feed the standby region pulls every few seconds. Needs the shared token."""
    token = os.environ.get('REPL_TOKEN', '')
    if not token or request.headers.get('X-Replication-Token') != token:
        return jsonify({'error': 'forbidden'}), 403
    return app.response_class(json.dumps(recovery.replication_feed(db), default=str), mimetype='application/json')


@app.route('/health')
def health():
    try:
        conn = db()
        with conn.cursor() as c:
            c.execute("SELECT 1")
            c.fetchone()
        conn.close()
        return jsonify({'status': 'healthy', 'service': 'securebank', 'region': AWS_REGION, 'db': 'connected',
                        's3_bucket': S3_BUCKET, 'server': SERVER_ID})
    except Exception as e:
        return jsonify({'status': 'degraded', 'db_error': str(e), 'server': SERVER_ID}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', '80')), debug=False)
