import pytest

from main import app


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("LOG_REQUESTS", "false")
    monkeypatch.setenv("APP_VERSION", "9.9.9")
    monkeypatch.setenv("GIT_SHA", "abc1234")
    monkeypatch.setenv("APP_ENV", "test")
    app.config.update(TESTING=True)
    return app.test_client()


def test_health_returns_healthy(client):
    response = client.get("/broken")
    assert response.status_code == 200
    assert response.get_json()["status"] == "healthy"


def test_info_returns_release_metadata(client):
    response = client.get("/api/info")
    assert response.status_code == 200
    body = response.get_json()
    assert body["version"] == "9.9.9"
    assert body["gitSha"] == "abc1234"
    assert body["environment"] == "test"


def test_index_returns_greeting(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.get_json()["service"] == "deployflow-app"


def test_unknown_route_returns_404(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404