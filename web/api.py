"""Client for the backend microservices (tier 2), reached through the internal load balancer.

The web tier has no database credentials: everything goes through these calls.
API_URL is the internal load balancer; USERS_URL / ACCOUNTS_URL / PASSBOOK_URL
override it per service (for example on Kubernetes or docker compose).
"""
import os
import re
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone

API_URL = os.environ.get('API_URL', 'http://localhost:5000').rstrip('/')
URLS = {
    'users': os.environ.get('USERS_URL', API_URL).rstrip('/'),
    'accounts': os.environ.get('ACCOUNTS_URL', API_URL).rstrip('/'),
    'passbook': os.environ.get('PASSBOOK_URL', API_URL).rstrip('/'),
}
TOKEN = os.environ.get('INTERNAL_TOKEN', '')
TIMEOUT = float(os.environ.get('API_TIMEOUT', '4'))
_ISO = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def _dates(o):
    """Turn ISO timestamps back into datetimes so the templates can format them."""
    if isinstance(o, dict):
        return {k: _dates(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_dates(v) for v in o]
    if isinstance(o, str) and _ISO.match(o):
        try:
            d = datetime.fromisoformat(o)
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            return o
    return o


def call(method, path, body=None, headers=None):
    service = path.strip('/').split('/')[0]
    url = URLS.get(service, API_URL) + path
    data = json.dumps(body).encode() if body is not None else None
    h = {'Content-Type': 'application/json', **(headers or {})}
    if TOKEN:
        h['X-Internal-Token'] = TOKEN
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return _dates(json.loads(r.read() or b'{}'))
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get('error', str(e))
        except Exception:
            msg = str(e)
        raise ApiError(e.code, msg)
    except Exception as e:
        raise ApiError(503, f"{service} service unreachable: {e}")


def get(path, headers=None):
    return call('GET', path, headers=headers)


def post(path, body):
    return call('POST', path, body)


def json_dumps(obj):
    return json.dumps(obj, default=lambda o: o.isoformat() if isinstance(o, datetime) else str(o))
