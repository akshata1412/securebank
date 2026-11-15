"""Tests that run in CI without a database or AWS."""
import os
import sys
import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "1")  # nothing listens here, so DB calls fail fast

import app as securebank  # noqa: E402

NOW = datetime.datetime(2026, 11, 15, 10, 30)
USERS = {"akshata": {"username": "akshata", "name": "Akshata Deshpande", "account": "ACC1001", "balance": 150000},
         "rahul": {"username": "rahul", "name": "Rahul Sharma", "account": "ACC1002", "balance": 30000}}
TXNS = [{"id": "TXN1002", "from_user": "rahul", "to_user": "akshata", "amount": 2750, "note": "Books",
         "timestamp": NOW, "backed_up": True},
        {"id": "TXN1001", "from_user": "akshata", "to_user": "rahul", "amount": 1500, "note": "",
         "timestamp": NOW, "backed_up": False}]


def client():
    securebank.app.config["TESTING"] = True
    return securebank.app.test_client()


def signed_in(monkeypatch):
    monkeypatch.setattr(securebank, "get_user", lambda u: USERS[u])
    monkeypatch.setattr(securebank, "get_all_users", lambda: USERS)
    monkeypatch.setattr(securebank, "get_user_transactions", lambda u, limit=None: TXNS)
    c = client()
    with c.session_transaction() as s:
        s["user"] = "akshata"
    return c


def test_indian_number_format():
    assert securebank.inr(150000) == "1,50,000"
    assert securebank.inr(12345678) == "1,23,45,678"
    assert securebank.inr(999) == "999"


def test_login_page_renders():
    r = client().get("/")
    assert r.status_code == 200
    assert b"Sign in" in r.data


def test_dashboard_requires_login():
    r = client().get("/dashboard")
    assert r.status_code == 302


def test_dashboard_shows_passbook(monkeypatch):
    r = signed_in(monkeypatch).get("/dashboard")
    assert r.status_code == 200
    assert b"1,50,000" in r.data
    assert b"Withdrawal (Rs)" in r.data
    assert b"From Rahul Sharma" in r.data


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
    assert b"1 of 2 servers healthy" in r.data
    assert b"Unreachable" in r.data


def test_infra_page_survives_without_aws():
    r = client().get("/infra")
    assert r.status_code == 200


def fake_dr(state, missing=()):
    return {"db_ok": state != "down", "dr_ok": True, "db_count": 9 - len(missing), "dr_count": 9,
            "missing": list(missing), "not_in_dr": [], "rpo": {"seconds": 14, "pending": False, "at": NOW},
            "events": [{"time": NOW.replace(tzinfo=datetime.timezone.utc), "level": "ok", "text": "Restored", "seconds": 4.2}],
            "rto": {"seconds": 112}, "state": state}


def test_dr_page_safe(monkeypatch):
    monkeypatch.setattr(securebank.recovery, "status", lambda _db: fake_dr("safe"))
    r = client().get("/dr")
    assert r.status_code == 200
    assert b"Every transaction has a safe copy" in r.data
    assert b"1 min 52 s" in r.data


def test_dr_page_flags_data_loss(monkeypatch):
    monkeypatch.setattr(securebank.recovery, "status", lambda _db: fake_dr("loss", ["TXN1001", "TXN1002"]))
    r = client().get("/dr")
    assert b"2 transactions are missing from the database" in r.data
    assert b"TXN1001, TXN1002" in r.data


def test_dr_page_survives_without_aws():
    r = client().get("/dr")
    assert r.status_code == 200
    assert b"database can" in r.data
