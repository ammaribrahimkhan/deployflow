import pytest

from main import app


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("LOG_REQUESTS", "false")
    monkeypatch.setenv("APP_VERSION", "9.9.9")
    monkeypatch.setenv("GIT_SHA", "abc1234")
    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("CONTAINER_APP_REVISION", "demo-app--rev1")
    monkeypatch.delenv("FAULT_INJECTION_PERCENT", raising=False)
    app.config.update(TESTING=True)
    return app.test_client()


def test_health_returns_healthy(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "healthy"


def test_info_returns_release_metadata(client):
    response = client.get("/api/info")
    assert response.status_code == 200
    body = response.get_json()
    assert body["version"] == "9.9.9"
    assert body["gitSha"] == "abc1234"
    assert body["environment"] == "test"
    assert body["revision"] == "demo-app--rev1"


def test_index_returns_greeting(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.get_json()["service"] == "deployflow-app"


def test_unknown_route_returns_404(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404


def test_fault_injection_is_off_by_default(client):
    for _ in range(10):
        assert client.get("/").status_code == 200


def test_fault_injection_at_100_percent_fails_index(client, monkeypatch):
    monkeypatch.setenv("FAULT_INJECTION_PERCENT", "100")
    assert client.get("/").status_code == 500


def test_health_is_never_affected_by_fault_injection(client, monkeypatch):
    monkeypatch.setenv("FAULT_INJECTION_PERCENT", "100")
    assert client.get("/health").status_code == 200


def test_invalid_fault_value_is_ignored(client, monkeypatch):
    monkeypatch.setenv("FAULT_INJECTION_PERCENT", "not-a-number")
    assert client.get("/").status_code == 200