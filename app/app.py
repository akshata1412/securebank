from flask import Flask, render_template_string, request, redirect, url_for, session, jsonify
import os
import json
import boto3
import uuid
import time
import pymysql
from datetime import datetime

import infra

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

LOGIN = """<!DOCTYPE html><html><head><title>SecureBank Login</title><style>""" + CSS + """body{display:flex;align-items:center;justify-content:center;padding:20px}.card{background:#1A2942;padding:40px;border-radius:12px;max-width:400px;width:100%}h1{font-size:36px;margin-bottom:5px}.tag{color:#C5583E;font-style:italic;margin-bottom:30px;font-size:14px}label{display:block;margin:15px 0 5px;color:#8FA4C4;font-size:12px;letter-spacing:1px}input{width:100%;padding:12px;background:#0F1B2D;border:1px solid #2A3952;border-radius:6px;color:#F4EFE6;font-size:14px}input:focus{outline:none;border-color:#C5583E}button{width:100%;padding:14px;background:#C5583E;color:white;border:none;border-radius:6px;font-size:14px;font-weight:bold;cursor:pointer;margin-top:20px;letter-spacing:1px}button:hover{background:#A64830}.hint{margin-top:20px;padding:15px;background:#0F1B2D;border-radius:6px;font-size:12px;color:#8FA4C4}.hint strong{color:#C5583E}.error{color:#ff6b6b;margin-top:10px;font-size:13px}.pill{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px;margin-bottom:15px}.pill2{display:inline-block;background:#1C4A6B;color:#B8D4E8;padding:4px 10px;border-radius:4px;font-size:10px;letter-spacing:1px;margin-left:5px;margin-bottom:15px}</style></head><body><div class="card"><div><span class="pill">EC2 + ALB</span><span class="pill2">RDS MySQL</span><span class="pill2">S3</span><span class="pill2">K8S</span></div><h1>SecureBank</h1><p class="tag">Cloud-native banking platform</p><form method="POST"><label>USERNAME</label><input type="text" name="username" required autofocus><label>PASSWORD</label><input type="password" name="password" required><button type="submit">LOG IN</button>{% if error %}<div class="error">{{ error }}</div>{% endif %}</form><div class="hint"><strong>Demo accounts:</strong><br>akshata / demo123<br>rahul / demo123<br>priya / demo123</div><a href="/infra" style="display:block;text-align:center;margin-top:16px;color:#8FA4C4;font-size:12px;text-decoration:none">View live infrastructure &rarr;</a></div></body></html>"""

DASH = """<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>SecureBank Dashboard</title><style>""" + CSS + """body{padding:20px}.container{max-width:960px;margin:0 auto}.header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px;padding:16px 0;border-bottom:1px solid #2A3952;margin-bottom:24px}.brand{display:flex;align-items:center;gap:12px}.logo{width:40px;height:40px;border-radius:10px;background:#C5583E;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:18px}.header h1{font-size:24px}.nav a{color:#8FA4C4;text-decoration:none;font-size:13px;margin-left:18px;letter-spacing:.5px}.nav a:hover,.nav a.on{color:#F4EFE6}.nav a.out{color:#C5583E}.hello{color:#8FA4C4;font-size:14px;margin-bottom:6px}.hello strong{color:#F4EFE6}.top{display:grid;grid-template-columns:1.4fr 1fr;gap:20px;margin-bottom:20px}.balance{background:linear-gradient(135deg,#1A2942,#22385A);padding:32px;border-radius:14px;position:relative;overflow:hidden}.balance:after{content:"";position:absolute;right:-40px;top:-40px;width:180px;height:180px;border-radius:50%;background:rgba(197,88,62,.12)}.lbl{color:#8FA4C4;font-size:11px;letter-spacing:2px;margin-bottom:10px}.amt{font-size:44px;font-weight:800;margin-bottom:8px}.acc{color:#C5583E;font-size:13px}.actions{display:grid;gap:12px}.btn{display:flex;align-items:center;justify-content:space-between;background:#1A2942;border:1px solid #2A3952;padding:20px;border-radius:12px;text-decoration:none;color:#F4EFE6}.btn:hover{border-color:#C5583E}.btn b{font-size:15px}.btn span{color:#8FA4C4;font-size:12px;display:block;margin-top:4px}.btn i{font-style:normal;color:#C5583E;font-size:20px}.card{background:#1A2942;padding:24px;border-radius:14px}.card h2{color:#C5583E;font-size:12px;letter-spacing:2px;margin-bottom:12px;display:flex;justify-content:space-between}.card h2 a{color:#8FA4C4;text-decoration:none;letter-spacing:.5px}.txn{display:flex;justify-content:space-between;align-items:center;padding:12px 0;border-bottom:1px solid #2A3952}.txn:last-child{border:none}.desc{font-size:14px}.meta{color:#8FA4C4;font-size:12px;margin-top:3px}.sent{color:#ff6b6b;font-weight:700}.recv{color:#97C459;font-weight:700}.badge{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:1px 6px;border-radius:4px;font-size:9px;margin-left:6px;letter-spacing:.5px}.empty{color:#8FA4C4;font-size:13px;padding:10px 0}.chip{display:inline-flex;align-items:center;gap:6px;background:#0F1B2D;border:1px solid #2A3952;padding:5px 10px;border-radius:999px;font-size:11px;color:#8FA4C4}.dot{width:7px;height:7px;border-radius:50%;background:#97C459}footer{display:flex;justify-content:space-between;flex-wrap:wrap;gap:10px;color:#5F7090;font-size:12px;margin-top:28px;padding:16px 0;border-top:1px solid #2A3952}footer a{color:#8FA4C4}@media(max-width:700px){.top{grid-template-columns:1fr}.amt{font-size:36px}.nav a{margin-left:0;margin-right:14px}}</style></head><body><div class="container"><div class="header"><div class="brand"><div class="logo">S</div><h1>SecureBank</h1></div><div class="nav"><a href="/dashboard" class="on">Dashboard</a><a href="/transfer">Transfer</a><a href="/history">History</a><a href="/infra">Infrastructure</a><a href="/logout" class="out">Log out</a></div></div><div class="hello">Welcome back, <strong>{{ user.name }}</strong></div><div class="top"><div class="balance"><div class="lbl">AVAILABLE BALANCE</div><div class="amt">Rs {{ "{:,}".format(user.balance) }}</div><div class="acc">Account {{ user.account }} · stored in Amazon RDS MySQL</div></div><div class="actions"><a class="btn" href="/transfer"><div><b>Send money</b><span>Saved to RDS, backed up to S3</span></div><i>&rarr;</i></a><a class="btn" href="/history"><div><b>Full history</b><span>With S3 backup badges</span></div><i>&rarr;</i></a><a class="btn" href="/infra"><div><b>Live infrastructure</b><span>See the AWS stack serving you</span></div><i>&rarr;</i></a></div></div><div class="card"><h2>RECENT ACTIVITY <a href="/history">View all</a></h2>{% if recent %}{% for txn in recent %}<div class="txn"><div><div class="desc">{% if txn.from_user == user.username %}Sent to <strong>{{ users[txn.to_user].name }}</strong>{% else %}Received from <strong>{{ users[txn.from_user].name }}</strong>{% endif %}{% if txn.backed_up %}<span class="badge">S3</span>{% endif %}</div><div class="meta">{{ txn.id }} · {{ txn.timestamp.strftime('%d %b %Y, %H:%M') }}{% if txn.note %} · {{ txn.note }}{% endif %}</div></div><div class="{% if txn.from_user == user.username %}sent{% else %}recv{% endif %}">{% if txn.from_user == user.username %}-{% else %}+{% endif %}Rs {{ "{:,}".format(txn.amount) }}</div></div>{% endfor %}{% else %}<div class="empty">No transactions yet. Make your first transfer.</div>{% endif %}</div><footer><span>SecureBank · CB3203B Cloud Computing · VIT Pune</span><span class="chip"><span class="dot"></span>served by {{ server_id }}</span></footer></div></body></html>"""

XFER = """<!DOCTYPE html><html><head><title>Transfer</title><style>""" + CSS + """body{padding:40px 20px}.container{max-width:500px;margin:0 auto}h1{font-size:28px;margin-bottom:5px}.back{color:#C5583E;text-decoration:none;font-size:13px;display:inline-block;margin-bottom:20px}.card{background:#1A2942;padding:30px;border-radius:12px;margin-top:20px}label{display:block;margin:15px 0 5px;color:#8FA4C4;font-size:12px;letter-spacing:1px}input,select{width:100%;padding:12px;background:#0F1B2D;border:1px solid #2A3952;border-radius:6px;color:#F4EFE6;font-size:14px}input:focus,select:focus{outline:none;border-color:#C5583E}input:disabled{opacity:0.6}button{width:100%;padding:14px;background:#C5583E;color:white;border:none;border-radius:6px;font-size:14px;font-weight:bold;cursor:pointer;margin-top:20px;letter-spacing:1px}button:hover{background:#A64830}.bal{color:#8FA4C4;font-size:13px;margin-top:10px}.success{background:#2C5F2D;color:#C9D8B8;padding:15px;border-radius:6px;margin-top:20px;font-size:14px}.error{background:#993556;color:#FBEAF0;padding:15px;border-radius:6px;margin-top:20px;font-size:14px}</style></head><body><div class="container"><a href="/dashboard" class="back">BACK TO DASHBOARD</a><h1>Transfer Money</h1><div class="card"><form method="POST"><label>FROM</label><input type="text" value="{{ user.account }} ({{ user.name }})" disabled><div class="bal">Available: Rs {{ "{:,}".format(user.balance) }}</div><label>TO (RECIPIENT)</label><select name="recipient" required><option value="">Select recipient...</option>{% for u, data in users.items() %}{% if u != current_user %}<option value="{{ u }}">{{ data.name }} ({{ data.account }})</option>{% endif %}{% endfor %}</select><label>AMOUNT (Rs)</label><input type="number" name="amount" min="1" max="{{ user.balance }}" required placeholder="Enter amount"><label>NOTE</label><input type="text" name="note" placeholder="Rent, Food, Gift, etc."><button type="submit">TRANSFER NOW</button></form>{% if success %}<div class="success">{{ success }}</div>{% endif %}{% if error %}<div class="error">{{ error }}</div>{% endif %}</div></div></body></html>"""

HIST = """<!DOCTYPE html><html><head><title>History</title><style>""" + CSS + """body{padding:40px 20px}.container{max-width:800px;margin:0 auto}h1{font-size:28px;margin-bottom:5px}.back{color:#C5583E;text-decoration:none;font-size:13px;display:inline-block;margin-bottom:20px}.sub{color:#8FA4C4;font-size:13px;margin-top:5px}.card{background:#1A2942;padding:25px;border-radius:12px;margin-top:20px}.txn{display:flex;justify-content:space-between;align-items:center;padding:15px 0;border-bottom:1px solid #2A3952}.txn:last-child{border:none}.id{color:#C5583E;font-size:12px;letter-spacing:1px}.desc{margin:5px 0;font-size:14px}.meta{color:#8FA4C4;font-size:12px}.amt{font-size:20px;font-weight:bold}.sent{color:#ff6b6b}.recv{color:#97C459}.empty{text-align:center;padding:40px;color:#8FA4C4}.badge{display:inline-block;background:#2C5F2D;color:#C9D8B8;padding:2px 8px;border-radius:4px;font-size:10px;margin-left:8px}</style></head><body><div class="container"><a href="/dashboard" class="back">BACK TO DASHBOARD</a><h1>Transaction History</h1><p class="sub">Loaded from RDS MySQL · S3 backup confirmations shown</p><div class="card">{% if transactions %}{% for txn in transactions %}<div class="txn"><div><div class="id">{{ txn.id }}{% if txn.backed_up %}<span class="badge">S3 BACKED UP</span>{% endif %}</div><div class="desc">{% if txn.from_user == current_user %}Sent to <strong>{{ users[txn.to_user].name }}</strong>{% else %}Received from <strong>{{ users[txn.from_user].name }}</strong>{% endif %}</div><div class="meta">{{ txn.timestamp.strftime('%Y-%m-%d %H:%M:%S') }}{% if txn.note %} · {{ txn.note }}{% endif %}</div></div><div class="amt {% if txn.from_user == current_user %}sent{% else %}recv{% endif %}">{% if txn.from_user == current_user %}-{% else %}+{% endif %}Rs {{ "{:,}".format(txn.amount) }}</div></div>{% endfor %}{% else %}<div class="empty">No transactions yet. Make your first transfer!</div>{% endif %}</div></div></body></html>"""


INFRA = """<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="5"><title>SecureBank Infrastructure</title><style>""" + CSS + """body{padding:20px}.container{max-width:1100px;margin:0 auto}.header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px;padding:16px 0;border-bottom:1px solid #2A3952;margin-bottom:20px}h1{font-size:24px}.sub{color:#8FA4C4;font-size:13px;margin-top:4px}.back{color:#C5583E;text-decoration:none;font-size:13px}.live{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:#97C459}.live i{width:8px;height:8px;border-radius:50%;background:#97C459;animation:p 1.4s infinite}@keyframes p{50%{opacity:.25}}.hero{background:linear-gradient(135deg,#1A2942,#22385A);border-radius:14px;padding:24px;margin-bottom:18px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:16px;align-items:center}.hero .lbl{color:#8FA4C4;font-size:11px;letter-spacing:2px}.hero .big{font-size:28px;font-weight:800;margin-top:6px}.hero .meta{color:#8FA4C4;font-size:13px;margin-top:6px}.hero .tag{background:#C5583E;color:#fff;padding:8px 14px;border-radius:999px;font-size:13px;font-weight:700}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px}.card{background:#1A2942;border-radius:14px;padding:20px;border-top:3px solid #2A3952}.card.ok{border-top-color:#97C459}.card.bad{border-top-color:#ff6b6b}.card.na{border-top-color:#5F7090}.card h2{font-size:12px;letter-spacing:2px;color:#8FA4C4;margin-bottom:4px}.card .svc{font-size:16px;font-weight:700;margin-bottom:12px}.st{float:right;font-size:11px;padding:3px 8px;border-radius:999px;font-weight:700;letter-spacing:.5px}.ok .st{background:#2C5F2D;color:#C9D8B8}.bad .st{background:#993556;color:#FBEAF0}.na .st{background:#2A3952;color:#8FA4C4}.row{display:flex;justify-content:space-between;gap:10px;font-size:13px;padding:7px 0;border-bottom:1px solid #22324D}.row:last-child{border:none}.row span{color:#8FA4C4}.row b{font-weight:600;text-align:right;word-break:break-all}.t{display:flex;justify-content:space-between;font-size:13px;padding:7px 0;border-bottom:1px solid #22324D}.t:last-child{border:none}.h{color:#97C459}.u{color:#ff6b6b}.d{color:#E8B04B}.err{color:#ff9b9b;font-size:12px}footer{color:#5F7090;font-size:12px;margin-top:20px;text-align:center}</style></head><body><div class="container"><div class="header"><div><h1>Live Infrastructure</h1><div class="sub">Every value below is read from AWS on this request · refreshes every 5 seconds</div></div><div><span class="live"><i></i>LIVE</span> &nbsp; <a class="back" href="/dashboard">&larr; Back to app</a></div></div>
<div class="hero"><div><div class="lbl">THIS REQUEST WAS SERVED BY</div><div class="big">{{ c.instance_name or c.container }}</div><div class="meta">{{ c.platform }}{% if c.az %} · {{ c.az }}{% endif %}{% if c.node %} · node {{ c.node }}{% endif %}{% if c.private_ip %} · {{ c.private_ip }}{% endif %}</div></div><div class="tag">{{ 'Kubernetes' if 'Kubernetes' in c.platform else 'Load-balanced EC2' }}</div></div>
<div class="grid">
<div class="card {{ 'ok' if lb.ok else ('na' if lb.ok is none else 'bad') }}"><h2>LOAD BALANCER</h2><div class="svc">Application Load Balancer <span class="st">{{ (lb.healthy|string + '/' + lb.total|string + ' HEALTHY') if lb.targets is defined else ('N/A' if lb.ok is none else 'ERROR') }}</span></div>{% if lb.targets is defined %}{% for t in lb.targets %}<div class="t"><span>{{ t.name }}</span><b class="{{ 'h' if t.state=='healthy' else ('u' if t.state=='unhealthy' else 'd') }}">{{ t.state }}{% if t.reason and t.state!='healthy' %} ({{ t.reason }}){% endif %}</b></div>{% endfor %}{% else %}<div class="err">{{ lb.error }}</div>{% endif %}</div>
<div class="card {{ 'ok' if d.ok else 'bad' }}"><h2>DATABASE</h2><div class="svc">Amazon RDS MySQL <span class="st">{{ 'CONNECTED' if d.ok else 'DOWN' }}</span></div>{% if d.ok %}<div class="row"><span>Instance</span><b>{{ d.host }}</b></div><div class="row"><span>Engine</span><b>MySQL {{ d.version }}</b></div><div class="row"><span>Query latency</span><b>{{ d.latency_ms }} ms</b></div><div class="row"><span>Customers</span><b>{{ d.users }}</b></div><div class="row"><span>Transactions</span><b>{{ d.transactions }} ({{ d.backed_up }} backed up)</b></div>{% else %}<div class="err">{{ d.error }}</div>{% endif %}</div>
<div class="card {{ 'ok' if b.ok and b.count else ('bad' if not b.ok else 'na') }}"><h2>BACKUP &amp; DISASTER RECOVERY</h2><div class="svc">Amazon S3 <span class="st">{{ ('REPLICATED' if b.in_dr else b.replication) if b.count else ('EMPTY' if b.ok else 'ERROR') }}</span></div>{% if b.ok and b.count %}<div class="row"><span>Backup files</span><b>{{ b.count }}</b></div><div class="row"><span>Latest backup</span><b>{{ b.latest_key }}</b></div><div class="row"><span>Written at</span><b>{{ b.latest_time.strftime('%d %b %H:%M:%S') }} UTC</b></div><div class="row"><span>Replication status</span><b>{{ b.replication }}</b></div><div class="row"><span>Copy in DR bucket</span><b class="{{ 'h' if b.in_dr else 'u' }}">{{ 'yes' if b.in_dr else 'not yet' }}</b></div>{% elif not b.ok %}<div class="err">{{ b.error }}</div>{% endif %}</div>
<div class="card {{ 'ok' if r.ok else ('na' if r.ok is none else 'bad') }}"><h2>DNS &amp; FAILOVER</h2><div class="svc">Amazon Route 53 <span class="st">{{ (r.healthy|string + '/' + r.total|string + ' CHECKERS OK') if r.total is defined else ('N/A' if r.ok is none else 'ERROR') }}</span></div>{% if r.total is defined %}<div class="row"><span>Record</span><b>{{ r.record }}</b></div><div class="row"><span>Routing</span><b>{{ r.routing }}</b></div><div class="row"><span>Health check</span><b>HTTP /health on the ALB</b></div><div class="row"><span>Global checkers healthy</span><b>{{ r.healthy }} of {{ r.total }}</b></div>{% else %}<div class="err">{{ r.error }}</div>{% endif %}</div>
<div class="card ok"><h2>COMPUTE</h2><div class="svc">{{ c.platform }} <span class="st">RUNNING</span></div><div class="row"><span>Container</span><b>{{ c.container }}</b></div>{% if c.instance_id %}<div class="row"><span>EC2 instance</span><b>{{ c.instance_id }}</b></div><div class="row"><span>Instance type</span><b>{{ c.instance_type }}</b></div>{% endif %}{% if c.az %}<div class="row"><span>Availability Zone</span><b>{{ c.az }}</b></div>{% endif %}{% if c.node %}<div class="row"><span>Kubernetes node</span><b>{{ c.node }}</b></div>{% endif %}<div class="row"><span>Region</span><b>{{ region }}</b></div></div>
<div class="card {{ 'ok' if sec.ok else 'bad' }}"><h2>SECURITY &amp; AUDIT</h2><div class="svc">AWS CloudTrail + KMS <span class="st">{{ 'LOGGING' if sec.ok else 'CHECK' }}</span></div>{% if sec.trail is defined %}<div class="row"><span>Trail</span><b>{{ sec.trail }}</b></div><div class="row"><span>All regions</span><b>{{ 'yes' if sec.multi_region else 'no' }}</b></div><div class="row"><span>Logs encrypted with KMS key</span><b>{{ sec.kms }}</b></div><div class="row"><span>Log file validation</span><b>{{ 'on' if sec.validation else 'off' }}</b></div><div class="row"><span>Last log delivered</span><b>{{ sec.last_delivery.strftime('%d %b %H:%M UTC') if sec.last_delivery else '-' }}</b></div>{% else %}<div class="err">{{ sec.error }}</div>{% endif %}</div>
</div><footer>SecureBank · CB3203B Cloud Computing · VIT Pune · page generated in {{ ms }} ms</footer></div></body></html>"""

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
    recent = get_user_transactions(session['user'])[:4]
    users = get_all_users()
    return render_template_string(DASH, user=user, recent=recent, users=users, server_id=SERVER_ID)


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


@app.route('/infra')
def infra_page():
    t0 = time.time()
    snap = infra.snapshot(db)
    return render_template_string(INFRA, c=snap['compute'], lb=snap['lb'], d=snap['database'], b=snap['backups'],
                                  r=snap['dns'], sec=snap['security'], region=AWS_REGION, ms=int((time.time() - t0) * 1000))


@app.route('/infra.json')
def infra_json():
    return jsonify(infra.snapshot(db))


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
