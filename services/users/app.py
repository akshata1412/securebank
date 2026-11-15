"""user-management microservice: sign-in and customer profiles.  Paths: /users/..."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from flask import request  # noqa: E402
from common.svc import create_app, db, out  # noqa: E402

app = create_app('user-management', 'users')
PUBLIC_FIELDS = "username, name, account, created_at"


@app.post('/users/login')
def login():
    body = request.get_json(silent=True) or {}
    u = str(body.get('username', '')).strip().lower()
    p = str(body.get('password', ''))
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute(f"SELECT {PUBLIC_FIELDS}, password FROM users WHERE username=%s", (u,))
            row = c.fetchone()
    finally:
        conn.close()
    if not row or row.pop('password') != p:
        return out({'error': "That username and password don't match."}, 401)
    return out({'user': row})


@app.get('/users')
def list_users():
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute(f"SELECT {PUBLIC_FIELDS} FROM users ORDER BY name")
            return out({'users': c.fetchall()})
    finally:
        conn.close()


@app.get('/users/<username>')
def get_user(username):
    conn = db()
    try:
        with conn.cursor() as c:
            c.execute(f"SELECT {PUBLIC_FIELDS} FROM users WHERE username=%s", (username,))
            row = c.fetchone()
    finally:
        conn.close()
    return out({'user': row}) if row else out({'error': 'not found'}, 404)
