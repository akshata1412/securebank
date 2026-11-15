"""Web tier tests: the backend APIs are faked, so no database or AWS is needed."""
import os
import datetime

from conftest import load, ROOT

web = load("web_app", "web/app.py")
api = web.api

NOW = datetime.datetime(2026, 11, 15, 10, 30, tzinfo=datetime.timezone.utc)
USERS = [{"username": "akshata", "name": "Akshata Deshpande", "account": "ACC1001"},
         {"username": "rahul", "name": "Rahul Sharma", "account": "ACC1002"}]
TXNS = [{"id": "TXN1002", "from_user": "rahul", "to_user": "akshata", "amount": 2750, "note": "Books",
         "timestamp": NOW, "backed_up": True},
        {"id": "TXN1001", "from_user": "akshata", "to_user": "rahul", "amount": 1500, "note": "",
         "timestamp": NOW, "backed_up": False}]


def fake_get(path, headers=None):
    if path == "/users":
        return {"users": USERS}
    if path.startswith("/users/") and not path.endswith("health"):
        return {"user": dict(USERS[0])}
    if path.startswith("/accounts/") and not path.endswith("health"):
        return {"username": "akshata", "account": "ACC1001", "balance": 150000}
    if path.startswith("/passbook/stats"):
        return {"ok": False, "error": "db down"}
    if path.startswith("/passbook/") and not path.endswith("health"):
        return {"entries": TXNS}
    return {"status": "healthy", "server": "svc-1"}


def client():
    web.app.config["TESTING"] = True
    return web.app.test_client()


def signed_in(monkeypatch):
    monkeypatch.setattr(api, "get", fake_get)
    c = client()
    with c.session_transaction() as s:
        s["user"] = "akshata"
    return c


def test_indian_number_format():
    assert web.inr(150000) == "1,50,000"
    assert web.inr(12345678) == "1,23,45,678"
    assert web.inr(999) == "999"


def test_ist_conversion():
    assert web.ist(datetime.datetime(2026, 11, 15, 10, 30)) == "15 Nov 2026, 4:00 PM"


def test_login_page_renders():
    r = client().get("/")
    assert r.status_code == 200 and b"Sign in" in r.data


def test_login_calls_user_service(monkeypatch):
    seen = {}

    def fake_post(path, body):
        seen["path"], seen["body"] = path, body
        return {"user": {"username": "akshata"}}
    monkeypatch.setattr(api, "post", fake_post)
    r = client().post("/", data={"username": "akshata", "password": "demo123"})
    assert r.status_code == 302 and seen["path"] == "/users/login"


def test_login_shows_service_error(monkeypatch):
    def bad(path, body):
        raise api.ApiError(401, "That username and password don't match.")
    monkeypatch.setattr(api, "post", bad)
    r = client().post("/", data={"username": "x", "password": "y"})
    assert b"don&#39;t match" in r.data


def test_dashboard_requires_login():
    assert client().get("/dashboard").status_code == 302


def test_dashboard_combines_three_services(monkeypatch):
    r = signed_in(monkeypatch).get("/dashboard")
    assert r.status_code == 200
    assert b"1,50,000" in r.data            # balance from account-management
    assert b"From Rahul Sharma" in r.data   # names from user-management, entries from passbook-management


def test_backend_down_shows_friendly_page(monkeypatch):
    c = signed_in(monkeypatch)

    def down(path, headers=None):
        raise api.ApiError(503, "users service unreachable")
    monkeypatch.setattr(api, "get", down)
    r = c.get("/dashboard")
    assert r.status_code == 503 and b"busy right now" in r.data


def test_transfer_posts_to_accounts(monkeypatch):
    c = signed_in(monkeypatch)
    seen = {}

    def fake_post(path, body):
        seen["path"], seen["body"] = path, body
        return {"transaction": dict(TXNS[1], id="TXN1003", amount=500)}
    monkeypatch.setattr(api, "post", fake_post)
    r = c.post("/transfer", data={"recipient": "rahul", "amount": "500", "note": "Lunch"})
    assert r.status_code == 200
    assert seen["path"] == "/accounts/transfer" and seen["body"]["to_user"] == "rahul"


def test_health_is_shallow():
    r = client().get("/health")
    assert r.status_code == 200 and r.get_json()["tier"] == "web"


def test_deep_health_fails_when_a_service_is_down():
    r = client().get("/health/deep")      # API_URL points at nothing
    assert r.status_code == 500 and r.get_json()["status"] == "degraded"


def test_web_tier_has_no_database_access():
    src = open(os.path.join(ROOT, "web", "app.py")).read() + open(os.path.join(ROOT, "web", "infra.py")).read()
    assert "pymysql" not in src and "DB_PASSWORD" not in src
    assert "pymysql" not in open(os.path.join(ROOT, "web", "requirements.txt")).read()


def test_infra_page_lists_microservices(monkeypatch):
    monkeypatch.setattr(api, "get", fake_get)
    monkeypatch.setattr(web.infra, "snapshot", lambda stats: {
        "compute": {"ok": True, "platform": "EC2 + Docker", "container": "abc", "node": "", "instance_id": "i-1",
                    "instance_name": "securebank-web-1", "az": "ap-southeast-2a", "instance_type": "t3.micro"},
        "lb": {"ok": True, "healthy": 1, "total": 2,
               "targets": [{"id": "i-1", "name": "securebank-web-1", "state": "healthy", "reason": ""},
                           {"id": "i-2", "name": "securebank-web-2", "state": "unused", "reason": "x"}]},
        "database": stats(), "backups": {"ok": True, "count": 0},
        "dns": {"ok": None, "error": "not set"}, "security": {"ok": False, "error": "denied"}})
    r = client().get("/infra")
    assert r.status_code == 200
    assert b"account-management" in r.data and b"3 of 3 services up" in r.data
    assert b"1 of 2 servers healthy" in r.data and b"Unreachable" in r.data


def test_dr_page_when_passbook_is_down():
    r = client().get("/dr")
    assert r.status_code == 200 and b"be reached" in r.data


def test_api_turns_iso_strings_into_datetimes():
    out = api._dates({"timestamp": "2026-11-15T10:30:00", "note": "2026 plans"})
    assert isinstance(out["timestamp"], datetime.datetime) and out["note"] == "2026 plans"
