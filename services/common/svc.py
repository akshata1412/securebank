"""Shared plumbing for the SecureBank microservices (tier 2).

Only these services hold database credentials. Each one reads its config from
environment variables, talks JSON, and exposes /health for the internal load
balancer. If INTERNAL_TOKEN is set, every request except /health must carry it
in the X-Internal-Token header (defence in depth on top of security groups).
"""
import os
import json
import socket
from datetime import datetime, date
from decimal import Decimal

import pymysql
from flask import Flask, Response, request

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
SERVER_ID = os.environ.get('SERVER_ID', socket.gethostname())

SCHEMA = [
    """CREATE TABLE IF NOT EXISTS users (
         username VARCHAR(50) PRIMARY KEY, password VARCHAR(100) NOT NULL, name VARCHAR(100) NOT NULL,
         account VARCHAR(20) NOT NULL, balance INT NOT NULL DEFAULT 0,
         created_at TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP)""",
    """CREATE TABLE IF NOT EXISTS transactions (
         id VARCHAR(20) PRIMARY KEY, from_user VARCHAR(50) NOT NULL, to_user VARCHAR(50) NOT NULL,
         from_account VARCHAR(20) NOT NULL, to_account VARCHAR(20) NOT NULL, amount INT NOT NULL,
         note VARCHAR(200), timestamp TIMESTAMP NULL DEFAULT CURRENT_TIMESTAMP, backed_up TINYINT(1) DEFAULT 0,
         FOREIGN KEY (from_user) REFERENCES users(username), FOREIGN KEY (to_user) REFERENCES users(username))""",
]


def db():
    return pymysql.connect(**DB_CONFIG)


def _default(o):
    if isinstance(o, (datetime, date)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return int(o) if o == int(o) else float(o)
    return str(o)


def out(obj, status=200):
    """JSON response with ISO-8601 timestamps."""
    return Response(json.dumps(obj, default=_default), status=status, mimetype='application/json')


def create_app(name, prefix):
    """A Flask app with the token check and /health routes every service needs."""
    app = Flask(name)
    token = os.environ.get('INTERNAL_TOKEN', '')

    @app.before_request
    def check_token():
        if token and not request.path.endswith('/health') and request.headers.get('X-Internal-Token') != token:
            return out({'error': 'forbidden'}, 403)

    def health():
        try:
            conn = db()
            with conn.cursor() as c:
                c.execute("SELECT 1")
            conn.close()
            return out({'status': 'healthy', 'service': name, 'server': SERVER_ID, 'db': 'connected'})
        except Exception as e:
            return out({'status': 'degraded', 'service': name, 'server': SERVER_ID, 'db_error': str(e)[:160]}, 500)

    # /health for the load balancer's target health check; /<prefix>/health through the internal load balancer
    app.add_url_rule('/health', 'health', health)
    app.add_url_rule(f'/{prefix}/health', 'prefixed_health', health)
    return app
