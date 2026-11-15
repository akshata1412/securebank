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
