"""Smoke tests that run in CI without a database."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "1")  # nothing listens here, so DB calls fail fast

import app as securebank  # noqa: E402


def client():
    securebank.app.config["TESTING"] = True
    return securebank.app.test_client()


def test_login_page_renders():
    r = client().get("/")
    assert r.status_code == 200
    assert b"SecureBank" in r.data


def test_dashboard_requires_login():
    r = client().get("/dashboard")
    assert r.status_code == 302
    assert r.headers["Location"].endswith("/")


def test_health_reports_degraded_without_db():
    r = client().get("/health")
    assert r.status_code == 500
    assert r.get_json()["status"] == "degraded"


def test_no_hardcoded_db_password():
    src = open(os.path.join(os.path.dirname(__file__), "..", "app", "app.py")).read()
    assert "DB_PASSWORD" in src
    assert "'password': '" not in src


FAKE_SNAPSHOT = {
    "compute": {"ok": True, "platform": "EC2 + Docker", "container": "abc123", "node": "",
                "instance_id": "i-0123", "instance_name": "securebank-web-1", "az": "ap-southeast-2a",
                "private_ip": "10.0.1.10", "instance_type": "t3.micro"},
    "lb": {"ok": True, "healthy": 1, "total": 2,
           "targets": [{"id": "i-1", "name": "securebank-web-1", "state": "healthy", "reason": ""},
                       {"id": "i-2", "name": "securebank-web-2", "state": "unused", "reason": "Target.InvalidState"}]},
    "database": {"ok": False, "error": "db down"},
    "backups": {"ok": True, "count": 0},
    "dns": {"ok": None, "error": "HEALTH_CHECK_ID not set"},
    "security": {"ok": False, "error": "denied"},
}


def test_infra_page_renders_mixed_states(monkeypatch):
    monkeypatch.setattr(securebank.infra, "snapshot", lambda _db: FAKE_SNAPSHOT)
    r = client().get("/infra")
    assert r.status_code == 200
    assert b"securebank-web-1" in r.data
    assert b"1/2 HEALTHY" in r.data
    assert b"DOWN" in r.data


def test_infra_page_survives_without_aws():
    r = client().get("/infra")
    assert r.status_code == 200
    assert b"Live Infrastructure" in r.data
