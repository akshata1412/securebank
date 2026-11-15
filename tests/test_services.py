"""Microservice tests with a fake database cursor."""
from conftest import load

users = load("users_app", "services/users/app.py")
accounts = load("accounts_app", "services/accounts/app.py")
passbook = load("passbook_app", "services/passbook/app.py")


class FakeCursor:
    def __init__(self, rows):
        self.rows, self.sql = list(rows), []

    def execute(self, sql, args=None):
        self.sql.append((sql, args))
        return 1

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None

    def fetchall(self):
        return self.rows.pop(0) if self.rows else []

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


class FakeConn:
    def __init__(self, rows):
        self.cur = FakeCursor(rows)
        self.committed = self.rolled_back = False

    def cursor(self):
        return self.cur

    def begin(self):
        pass

    def commit(self):
        self.committed = True

    def rollback(self):
        self.rolled_back = True

    def close(self):
        pass


def use(monkeypatch, module, rows):
    conn = FakeConn(rows)
    monkeypatch.setattr(module, "db", lambda: conn)
    return conn


def test_login_ok_hides_password(monkeypatch):
    use(monkeypatch, users, [{"username": "akshata", "name": "A", "account": "ACC1001", "created_at": None,
                              "password": "demo123"}])
    r = users.app.test_client().post("/users/login", json={"username": "Akshata ", "password": "demo123"})
    assert r.status_code == 200
    assert r.get_json()["user"]["username"] == "akshata" and "password" not in r.get_json()["user"]


def test_login_wrong_password(monkeypatch):
    use(monkeypatch, users, [{"username": "akshata", "name": "A", "account": "x", "created_at": None, "password": "p"}])
    r = users.app.test_client().post("/users/login", json={"username": "akshata", "password": "nope"})
    assert r.status_code == 401


def test_users_list_never_selects_passwords(monkeypatch):
    conn = use(monkeypatch, users, [[{"username": "akshata", "name": "A", "account": "x", "created_at": None}]])
    r = users.app.test_client().get("/users")
    assert r.status_code == 200 and "password" not in conn.cur.sql[0][0]


def test_transfer_moves_money_in_one_transaction(monkeypatch):
    monkeypatch.setattr(accounts, "backup", lambda txn: True)
    conn = use(monkeypatch, accounts, [{"balance": 1000, "account": "ACC1001"}, {"account": "ACC1002"},
                                       {"m": 1009}, {"id": "TXN1010", "amount": 300}])
    r = accounts.app.test_client().post("/accounts/transfer",
                                        json={"from_user": "akshata", "to_user": "rahul", "amount": 300})
    assert r.status_code == 200 and r.get_json()["transaction"]["id"] == "TXN1010"
    assert conn.committed
    assert any("FOR UPDATE" in s for s, _ in conn.cur.sql)


def test_transfer_rejects_overdraft(monkeypatch):
    conn = use(monkeypatch, accounts, [{"balance": 100, "account": "ACC1001"}, {"account": "ACC1002"}])
    r = accounts.app.test_client().post("/accounts/transfer",
                                        json={"from_user": "akshata", "to_user": "rahul", "amount": 500})
    assert r.status_code == 400 and conn.rolled_back


def test_transfer_validates_input():
    c = accounts.app.test_client()
    assert c.post("/accounts/transfer", json={"from_user": "a", "to_user": "b", "amount": 0}).status_code == 400
    assert c.post("/accounts/transfer", json={"from_user": "a", "to_user": "a", "amount": 5}).status_code == 400


def test_passbook_limit(monkeypatch):
    conn = use(monkeypatch, passbook, [[{"id": "TXN1001"}]])
    r = passbook.app.test_client().get("/passbook/akshata?limit=6")
    assert r.status_code == 200 and "LIMIT 6" in conn.cur.sql[0][0]


def test_health_reports_degraded_without_db():
    r = users.app.test_client().get("/users/health")
    assert r.status_code == 500 and r.get_json()["status"] == "degraded"


def test_internal_token_required(monkeypatch):
    monkeypatch.setenv("INTERNAL_TOKEN", "s3cret")
    svc = load("users_tok", "services/users/app.py")
    use(monkeypatch, svc, [[]])
    c = svc.app.test_client()
    assert c.get("/users").status_code == 403
    assert c.get("/users", headers={"X-Internal-Token": "s3cret"}).status_code == 200


def test_replication_feed_needs_token(monkeypatch):
    monkeypatch.setenv("REPL_TOKEN", "t")
    monkeypatch.setattr(passbook.recovery, "replication_feed", lambda db: {"customers": [], "transactions": []})
    c = passbook.app.test_client()
    assert c.get("/passbook/replication.json").status_code == 403
    assert c.get("/passbook/replication.json", headers={"X-Replication-Token": "t"}).status_code == 200
