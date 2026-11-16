"""passbook-management microservice: transaction history and the DR checks.  Paths: /passbook/..."""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from flask import request  # noqa: E402
from common.svc import create_app, db, out  # noqa: E402
import recovery  # noqa: E402

app = create_app('passbook-management', 'passbook')


def _short_host(host):
    """RDS endpoint -> its first label (securebank-db); an IP address (the Mumbai replica) stays whole."""
    return host if host.replace('.', '').isdigit() else host.split('.')[0]


@app.get('/passbook/<username>')
def passbook(username):
    sql = """SELECT * FROM transactions WHERE from_user=%s OR to_user=%s ORDER BY timestamp DESC, id DESC"""
    limit = request.args.get('limit', type=int)
    if limit:
        sql += f" LIMIT {int(limit)}"
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute(sql, (username, username))
            return out({'entries': c.fetchall()})
    finally:
        conn.close()


@app.get('/passbook/dr/status')
def dr_status():
    return out(recovery.status(db))


@app.get('/passbook/stats')
def stats():
    """Database figures for the web tier's Infrastructure page (the web tier has no DB access)."""
    try:
        t0 = time.time()
        conn = db()
        try:
            with conn.cursor() as c:
                c.execute("SELECT COUNT(*) AS n FROM users")
                users = c.fetchone()['n']
                c.execute("SELECT COUNT(*) AS n, SUM(backed_up) AS b, MAX(timestamp) AS last FROM transactions")
                row = c.fetchone()
                c.execute("SELECT VERSION() AS v")
                version = c.fetchone()['v']
        finally:
            conn.close()
        return out({'ok': True, 'latency_ms': int((time.time() - t0) * 1000), 'users': users,
                    'transactions': row['n'], 'backed_up': int(row['b'] or 0), 'last': row['last'],
                    'version': version, 'host': _short_host(os.environ.get('DB_HOST', ''))})
    except Exception as e:
        return out({'ok': False, 'error': str(e)[:160]})


@app.get('/passbook/replication.json')
def replication():
    """Feed for the Mumbai standby (until the binlog replica replaces it). Needs the shared token."""
    token = os.environ.get('REPL_TOKEN', '')
    if not token or request.headers.get('X-Replication-Token') != token:
        return out({'error': 'forbidden'}, 403)
    return out(recovery.replication_feed(db))
