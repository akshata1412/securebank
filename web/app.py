"""SecureBank web tier (tier 1).

Renders the pages customers see. It holds no database credentials: every
read and write goes to the backend microservices through the internal load
balancer (see api.py). Runs behind the public load balancer in AZ a and AZ b.
"""
import os
import time
import socket
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor

from flask import Flask, render_template, request, redirect, url_for, session, jsonify, Response

import api
import infra

app = Flask(__name__, root_path=os.path.dirname(os.path.abspath(__file__)))
# Same key on every web server so sign-in sessions work behind the load balancer
app.secret_key = os.environ.get('SECRET_KEY', 'change-me')

SERVER_ID = os.environ.get('SERVER_ID', socket.gethostname())
AWS_REGION = os.environ.get('AWS_REGION', 'ap-southeast-2')
IST = timezone(timedelta(hours=5, minutes=30))
SERVICES = [('user-management', '/users/health'), ('account-management', '/accounts/health'),
            ('passbook-management', '/passbook/health')]


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
    """Show a UTC timestamp in Indian time."""
    if not ts:
        return ''
    if isinstance(ts, str):
        return ts
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(IST).strftime(fmt).replace(' 0', ' ')


app.jinja_env.filters['inr'] = inr
app.jinja_env.filters['ist'] = ist


@app.context_processor
def page_globals():
    return {'server_id': SERVER_ID, 'signed_in': 'user' in session}


# ============ BACKEND CALLS ============

def get_user(username):
    """Profile from user-management plus balance from account-management."""
    user = api.get(f'/users/{username}')['user']
    user['balance'] = api.get(f'/accounts/{username}')['balance']
    return user


def get_all_users():
    return {u['username']: u for u in api.get('/users')['users']}


def get_user_transactions(username, limit=None):
    q = f'?limit={int(limit)}' if limit else ''
    return api.get(f'/passbook/{username}{q}')['entries']


def greeting():
    h = datetime.now(IST).hour
    return 'Good morning' if h < 12 else ('Good afternoon' if h < 17 else 'Good evening')


def backend_down(e):
    return render_template('login.html', error=f"Our banking service is busy right now ({e.message}). Try again in a minute."), 503


# ============ ROUTES ============

@app.route('/', methods=['GET', 'POST'])
def login():
    if 'user' in session:
        return redirect(url_for('dashboard'))
    error = None
    if request.method == 'POST':
        try:
            r = api.post('/users/login', {'username': request.form.get('username', ''),
                                          'password': request.form.get('password', '')})
            session['user'] = r['user']['username']
            return redirect(url_for('dashboard'))
        except api.ApiError as e:
            error = (e.message if e.status == 401 else "We can't reach the bank right now. Try again in a minute.")
    return render_template('login.html', error=error)


@app.route('/dashboard')
def dashboard():
    if 'user' not in session:
        return redirect(url_for('login'))
    try:
        return render_template('dashboard.html', page='dashboard', user=get_user(session['user']),
                               users=get_all_users(), entries=get_user_transactions(session['user'], limit=6),
                               greeting=greeting())
    except api.ApiError as e:
        return backend_down(e)


@app.route('/transfer', methods=['GET', 'POST'])
def transfer():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    try:
        user, users = get_user(cu), get_all_users()
        done = error = None
        if request.method == 'POST':
            r = request.form.get('recipient')
            if r not in users or r == cu:
                error = "Choose who to send the money to."
            else:
                try:
                    done = api.post('/accounts/transfer', {'from_user': cu, 'to_user': r,
                                                           'amount': request.form.get('amount', 0),
                                                           'note': request.form.get('note', '')})['transaction']
                    user = get_user(cu)
                except api.ApiError as e:
                    if e.status >= 500:
                        raise
                    error = e.message
        return render_template('transfer.html', page='transfer', user=user, users=users, current_user=cu,
                               done=done, error=error)
    except api.ApiError as e:
        return backend_down(e)


@app.route('/history')
def history():
    if 'user' not in session:
        return redirect(url_for('login'))
    cu = session['user']
    try:
        return render_template('history.html', page='history', user=get_user(cu), users=get_all_users(),
                               entries=get_user_transactions(cu))
    except api.ApiError as e:
        return backend_down(e)


@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))


def services_health():
    def one(item):
        name, path = item
        t0 = time.time()
        try:
            r = api.get(path)
            return {'name': name, 'ok': True, 'server': r.get('server', ''), 'ms': int((time.time() - t0) * 1000)}
        except api.ApiError as e:
            return {'name': name, 'ok': False, 'error': e.message[:120]}
    with ThreadPoolExecutor(max_workers=3) as pool:
        return list(pool.map(one, SERVICES))


def db_stats():
    try:
        return api.get('/passbook/stats')
    except api.ApiError as e:
        return {'ok': False, 'error': e.message[:160]}


@app.route('/infra')
def infra_page():
    t0 = time.time()
    snap = infra.snapshot(db_stats)
    snap['services'] = services_health()
    return render_template('infra.html', page='infra', s=snap, region=AWS_REGION,
                           ms=int((time.time() - t0) * 1000))


@app.route('/infra.json')
def infra_json():
    snap = infra.snapshot(db_stats)
    snap['services'] = services_health()
    return jsonify(snap)


def dr_report():
    try:
        return api.get('/passbook/dr/status')
    except api.ApiError as e:
        return {'db_ok': False, 'dr_ok': False, 'db_error': e.message, 'missing': [], 'not_in_dr': [],
                'events': [], 'rpo': None, 'rto': None, 'state': 'down'}


@app.route('/dr')
def dr_page():
    t0 = time.time()
    return render_template('dr.html', page='dr', r=dr_report(), ms=int((time.time() - t0) * 1000))


@app.route('/dr.json')
def dr_json():
    return jsonify(dr_report())


@app.route('/replication.json')
def replication():
    """Pass the Mumbai standby's feed request through to passbook-management (token checked there)."""
    try:
        feed = api.get('/passbook/replication.json',
                       headers={'X-Replication-Token': request.headers.get('X-Replication-Token', '')})
        return app.response_class(api.json_dumps(feed), mimetype='application/json')
    except api.ApiError as e:
        return jsonify({'error': e.message}), e.status


@app.route('/health')
def health():
    """Shallow check for the public load balancer: is this web container up?"""
    return jsonify({'status': 'healthy', 'tier': 'web', 'service': 'securebank-web', 'server': SERVER_ID,
                    'region': AWS_REGION})


@app.route('/health/deep')
def health_deep():
    """End-to-end check for Route 53: web -> every microservice -> database."""
    svcs = services_health()
    ok = all(s['ok'] for s in svcs)
    return Response(api.json_dumps({'status': 'healthy' if ok else 'degraded', 'server': SERVER_ID,
                                    'region': AWS_REGION, 'services': svcs}),
                    status=200 if ok else 500, mimetype='application/json')


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', '80')), debug=False)
