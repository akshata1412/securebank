from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify
import os
import json
import boto3
import uuid
import pymysql
from datetime import datetime

app = Flask(__name__)
# Same key on every server so login sessions work behind the load balancer
app.secret_key = os.environ.get('SECRET_KEY', 'change-me')

# Which server/pod handled the request (shown in the footer and /health)
SERVER_ID = os.environ.get('SERVER_ID', os.environ.get('HOSTNAME', 'local'))

# ============ DATABASE CONFIG ============
# Credentials come from environment variables (Docker -e / Kubernetes Secret),
# never from source code.
DB_CONFIG = {
    'host': os.environ.get('DB_HOST', 'localhost'),
    'user': os.environ.get('DB_USER', 'admin'),
    'password': os.environ.get('DB_PASSWORD', ''),
    'database': os.environ.get('DB_NAME', 'securebank'),
    'port': int(os.environ.get('DB_PORT', '3306')),
    'cursorclass': pymysql.cursors.DictCursor,
    'autocommit': True
}


def db():
    return pymysql.connect(**DB_CONFIG)


# ============ S3 CONFIG ============
S3_BUCKET = os.environ.get('S3_BUCKET', 'securebank-backups-akshata-2026')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
s3 = boto3.client('s3', region_name=AWS_REGION)


def backup(txn):
    try:
        ts = datetime.now().strftime('%Y%m%d-%H%M%S-') + str(uuid.uuid4())[:8]
        s3.put_object(Bucket=S3_BUCKET, Key=f'transactions/live/{ts}.json',
                      Body=json.dumps(txn, indent=2, default=str),
                      ContentType='application/json')
        return True
    except Exception as e:
        print(f"S3 error: {e}")
        return False

# ============ DB HELPERS ============


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
    with conn.cursor() as c:
        c.execute("SELECT * FROM users")
        rows = c.fetchall()
    conn.close()
    return {row['username']: row for row in rows}


def do_transfer(from_user, to_user, amount, note):
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute("SELECT balance, account FROM users WHERE username=%s FOR UPDATE", (from_user,))
            from_data = c.fetchone()
            c.execute("SELECT account FROM users WHERE username=%s", (to_user,))
            to_data = c.fetchone()

            if from_data['balance'] < amount:
                return None, "Insufficient balance"

            c.execute("UPDATE users SET balance = balance - %s WHERE username=%s", (amount, from_user))
            c.execute("UPDATE users SET balance = balance + %s WHERE username=%s", (amount, to_user))

            c.execute("SELECT COUNT(*) as cnt FROM transactions")
            txn_id = f"TXN{c.fetchone()['cnt'] + 1001:04d}"

            c.execute("""INSERT INTO transactions (id, from_user, to_user, from_account, to_account, amount, note, backed_up)
                         VALUES (%s, %s, %s, %s, %s, %s, %s, FALSE)""",
                      (txn_id, from_user, to_user, from_data['account'], to_data['account'], amount, note))

            c.execute("SELECT * FROM transactions WHERE id=%s", (txn_id,))
            txn = c.fetchone()

        backed_up = backup(txn)
        if backed_up:
            with conn.cursor() as c:
                c.execute("UPDATE transactions SET backed_up=TRUE WHERE id=%s", (txn_id,))
                txn['backed_up'] = True

        return txn, None
    finally:
        conn.close()


def get_user_transactions(username):
    conn = db()
    with conn.cursor() as c:
        c.execute("""SELECT * FROM transactions
                     WHERE from_user=%s OR to_user=%s
                     ORDER BY timestamp DESC""", (username, username))
        rows = c.fetchall()
    conn.close()
    return rows


# ============ TEMPLATES ============
CSS = "*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,sans-serif;background:#0F1B2D;color:#F4EFE6;min-height:100vh}"

LOGIN = """<!DOCTYPE html><html><head><title>SecureBank Login</title><style>""" + CSS + """body{display:flex;align-items:center;justify-content:center;padding:20px}.card{background:#1A2942;padding:40px;border-radius:12px;max-width:400px;width:100%}h1{font-size:36px;margin-bottom:5px}.tag{color:#C5583E;font-style:italic;margin-bottom:30px;font-size:14px}label{display:block;margin:15px 0 5px;color:#8FA4C4;font-size:12px;letter-spacing:1px}input{width:100%;padding:12px;background:#0F1B2D;border:1px solid #2A3952;border-radius:6px;color:#F4EFE6;font-size:14px}input:focus{outline:none;border-color:#C5583E}button{width:100%;padding:14px;background:#C5583E;color:white;border:none;border-radius:6px;font-size:14px;font-weight:bold;cursor:pointer;margin-top:20px;letter-spacing:1px}button:hover{background:#A64830}.hint{margin-top:20px;padding:15px;background:#0F1B2D;border-radius:6px;font-size:12px;color:#8FA4C4}.hint strong{color:#C5583E}.error{color:#ff6b6b;margin-top:10px;font-size:13px}.pill{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px;margin-bottom:15px}.pill2{display:inline-block;background:#1C4A6B;color:#B8D4E8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px;margin-left:5px;margin-bottom:15px}</style></head><body><div class="card"><div><span class="pill">EC2</span><span class="pill2">RDS MySQL</span><span class="pill2">S3</span></div><h1>SecureBank</h1><p class="tag">Cloud-native banking platform</p><form method="POST"><label>USERNAME</label><input type="text" name="username" required autofocus><label>PASSWORD</label><input type="password" name="password" required><button type="submit">LOG IN</button>{% if error %}<div class="error">{{ error }}</div>{% endif %}</form><div class="hint"><strong>Demo accounts:</strong><br>akshata / demo123<br>rahul / demo123<br>priya / demo123</div></div></body></html>"""

DASH = """<!DOCTYPE html><html><head><title>SecureBank Dashboard</title><style>""" + CSS + """body{padding:20px}.container{max-width:900px;margin:0 auto}.header{display:flex;justify-content:space-between;align-items:center;padding:20px 0;border-bottom:1px solid #2A3952;margin-bottom:30px}.header h1{font-size:28px}.header .user{color:#8FA4C4;font-size:14px}.logout{color:#C5583E;text-decoration:none;font-size:13px;margin-left:20px}.balance{background:#1A2942;padding:40px;border-radius:12px;margin-bottom:30px}.balance .lbl{color:#8FA4C4;font-size:12px;letter-spacing:2px;margin-bottom:10px}.balance .amt{font-size:48px;font-weight:bold;margin-bottom:10px}.balance .acc{color:#C5583E;font-size:14px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}.card{background:#1A2942;padding:30px;border-radius:12px}.card h2{color:#C5583E;font-size:14px;letter-spacing:2px;margin-bottom:20px}.card p{color:#8FA4C4;font-size:13px;line-height:1.6;margin-bottom:15px}.card a{display:block;background:#C5583E;color:white;text-align:center;padding:14px;border-radius:6px;text-decoration:none;font-weight:bold;letter-spacing:1px}.card a:hover{background:#A64830}.pill{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px}.pill2{display:inline-block;background:#1C4A6B;color:#B8D4E8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px;margin-left:5px}footer{text-align:center;color:#5F7090;font-size:12px;margin-top:40px;padding:20px}@media(max-width:600px){.grid{grid-template-columns:1fr}}</style></head><body><div class="container"><div class="header"><div><h1>SecureBank</h1><span class="pill">EC2</span><span class="pill2">RDS MySQL</span><span class="pill2">S3</span></div><div><span class="user">Hi, <strong>{{ user.name }}</strong></span><a href="/logout" class="logout">LOG OUT</a></div></div><div class="balance"><div class="lbl">AVAILABLE BALANCE</div><div class="amt">Rs {{ "{:,}".format(user.balance) }}</div><div class="acc">Account: {{ user.account }}  ·  Data persisted in RDS MySQL</div></div><div class="grid"><div class="card"><h2>TRANSFER MONEY</h2><p>Send money to another SecureBank account. Transaction stored in RDS MySQL and backed up to S3 Sydney.</p><a href="/transfer">NEW TRANSFER</a></div><div class="card"><h2>TRANSACTION HISTORY</h2><p>View all your past transactions from the RDS database with S3 backup confirmation badges.</p><a href="/history">VIEW HISTORY</a></div></div><footer>SecureBank · Cloud Computing CB3203B · VIT Pune<br><small>EC2 + RDS MySQL + S3 · Sydney Region · served by {{ server_id }}</small></footer></div></body></html>"""

XFER = """<!DOCTYPE html><html><head><title>Transfer</title><style>""" + CSS + """body{padding:40px 20px}.container{max-width:500px;margin:0 auto}h1{font-size:28px;margin-bottom:5px}.back{color:#C5583E;text-decoration:none;font-size:13px;display:inline-block;margin-bottom:20px}.card{background:#1A2942;padding:30px;border-radius:12px;margin-top:20px}label{display:block;margin:15px 0 5px;color:#8FA4C4;font-size:12px;letter-spacing:1px}input,select{width:100%;padding:12px;background:#0F1B2D;border:1px solid #2A3952;border-radius:6px;color:#F4EFE6;font-size:14px}input:focus,select:focus{outline:none;border-color:#C5583E}input:disabled{opacity:0.6}button{width:100%;padding:14px;background:#C5583E;color:white;border:none;border-radius:6px;font-size:14px;font-weight:bold;cursor:pointer;margin-top:20px;letter-spacing:1px}button:hover{background:#A64830}.bal{color:#8FA4C4;font-size:13px;margin-top:10px}.success{background:#2C5F2D;color:#C9D8B8;padding:15px;border-radius:6px;margin-top:20px;font-size:14px}.error{background:#993556;color:#FBEAF0;padding:15px;border-radius:6px;margin-top:20px;font-size:14px}</style></head><body><div class="container"><a href="/dashboard" class="back">BACK TO DASHBOARD</a><h1>Transfer Money</h1><div class="card"><form method="POST"><label>FROM</label><input type="text" value="{{ user.account }} ({{ user.name }})" disabled><div class="bal">Available: Rs {{ "{:,}".format(user.balance) }}</div><label>TO (RECIPIENT)</label><select name="recipient" required><option value="">Select recipient...</option>{% for u, data in users.items() %}{% if u != current_user %}<option value="{{ u }}">{{ data.name }} ({{ data.account }})</option>{% endif %}{% endfor %}</select><label>AMOUNT (Rs)</label><input type="number" name="amount" min="1" max="{{ user.balance }}" required placeholder="Enter amount"><label>NOTE</label><input type="text" name="note" placeholder="Rent, Food, Gift, etc."><button type="submit">TRANSFER NOW</button></form>{% if success %}<div class="success">{{ success }}</div>{% endif %}{% if error %}<div class="error">{{ error }}</div>{% endif %}</div></div></body></html>"""

HIST = """<!DOCTYPE html><html><head><title>History</title><style>""" + CSS + """body{padding:40px 20px}.container{max-width:800px;margin:0 auto}h1{font-size:28px;margin-bottom:5px}.back{color:#C5583E;text-decoration:none;font-size:13px;display:inline-block;margin-bottom:20px}.sub{color:#8FA4C4;font-size:13px;margin-top:5px}.card{background:#1A2942;padding:25px;border-radius:12px;margin-top:20px}.txn{display:flex;justify-content:space-between;align-items:center;padding:15px 0;border-bottom:1px solid #2A3952}.txn:last-child{border:none}.id{color:#C5583E;font-size:12px;letter-spacing:1px}.desc{margin:5px 0;font-size:14px}.meta{color:#8FA4C4;font-size:12px}.amt{font-size:20px;font-weight:bold}.sent{color:#ff6b6b}.recv{color:#97C459}.empty{text-align:center;padding:40px;color:#8FA4C4}.badge{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:2px 8px;border-radius:4px;font-size:10px;margin-left:8px}</style></head><body><div class="container"><a href="/dashboard" class="back">BACK TO DASHBOARD</a><h1>Transaction History</h1><p class="sub">Loaded from RDS MySQL · S3 backup confirmations shown</p><div class="card">{% if transactions %}{% for txn in transactions %}<div class="txn"><div><div class="id">{{ txn.id }}{% if txn.backed_up %}<span class="badge">S3 BACKED UP</span>{% endif %}</div><div class="desc">{% if txn.from_user == current_user %}Sent to <strong>{{ users[txn.to_user].name }}</strong>{% else %}Received from <strong>{{ users[txn.from_user].name }}</strong>{% endif %}</div><div class="meta">{{ txn.timestamp.strftime('%Y-%m-%d %H:%M:%S') }}{% if txn.note %} · {{ txn.note }}{% endif %}</div></div><div class="amt {% if txn.from_user == current_user %}sent{% else %}recv{% endif %}">{% if txn.from_user == current_user %}-{% else %}+{% endif %}Rs {{ "{:,}".format(txn.amount) }}</div></div>{% endfor %}{% else %}<div class="empty">No transactions yet. Make your first transfer!</div>{% endif %}</div></div></body></html>"""

# ============ ROUTES ============


@app.route('/', methods=['GET', 'POST'])
def login():
    if 'user' in session:
        return redirect(url_for('dashboard'))
    error = None
    if request.method == 'POST':
        u = request.form.get('username')
        p = request.form.get('password')
        user = get_user(u)
        if user and user['password'] == p:
            session['user'] = u
            return redirect(url_for('dashboard'))
        error = "Invalid username or password"
    return render_template_string(LOGIN, error=error)


@app.route('/dashboard')
def dashboard():
    if 'user' not in session:
        return redirect(url_for('login'))
    user = get_user(session['user'])
    return render_template_string(DASH, user=user, bucket=S3_BUCKET, server_id=SERVER_ID)


@app.route('/transfer', methods=['GET', 'POST'])
def transfer():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    user = get_user(cu)
    users = get_all_users()
    success = error = None
    if request.method == 'POST':
        r = request.form.get('recipient')
        try:
            a = int(request.form.get('amount', 0))
        except:
            a = 0
        n = request.form.get('note', '')
        if r not in users:
            error = "Invalid recipient"
        elif a <= 0:
            error = "Amount must be positive"
        elif a > user['balance']:
            error = "Insufficient balance"
        else:
            txn, err = do_transfer(cu, r, a, n)
            if err:
                error = err
            else:
                success = f"Transferred Rs {a:,} to {users[r]['name']}." + (" Saved to RDS + S3." if txn['backed_up'] else " Saved to RDS. (S3 backup pending)")
                user = get_user(cu)
    return render_template_string(XFER, user=user, users=users, current_user=cu, success=success, error=error)


@app.route('/history')
def history():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    users = get_all_users()
    txns = get_user_transactions(cu)
    return render_template_string(HIST, transactions=txns, users=users, current_user=cu)


@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


@app.route('/health')
def health():
    try:
        conn = db()
        with conn.cursor() as c:
            c.execute("SELECT 1")
            c.fetchone()
        conn.close()
        return jsonify({'status': 'healthy', 'service': 'securebank', 'region': AWS_REGION, 'db': 'connected', 's3_bucket': S3_BUCKET, 'server': SERVER_ID})
    except Exception as e:
        return jsonify({'status': 'degraded', 'db_error': str(e), 'server': SERVER_ID}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', '80')), debug=False)
