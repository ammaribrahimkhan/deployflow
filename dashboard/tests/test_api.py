import pytest

import config
import main

CSRF = {"X-DeployFlow-CSRF": "1"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(config, "AUTH_MODE", "local")
    monkeypatch.setattr(config, "ACTIONS_ENABLED", True)
    main._rate_limit.clear()
    main._cache.clear()
    main.app.config.update(TESTING=True)
    return main.app.test_client()


@pytest.fixture
def queued(monkeypatch):
    calls = []
    monkeypatch.setattr(main.azure_api, "pipeline_ids", lambda: {"deployflow-rollback": 7, "deployflow-cd": 5})

    def fake_queue(pipeline_id, parameters):
        calls.append((pipeline_id, parameters))
        return {"id": 99, "_links": {"web": {"href": "https://dev.azure.com/org/project/_build/results?buildId=99"}}}

    monkeypatch.setattr(main.azure_api, "queue_pipeline", fake_queue)
    return calls


def sign_in(client, role):
    response = client.get("/login?token=" + main.LOCAL_TOKENS[role])
    assert response.status_code == 302


def test_healthz_needs_no_sign_in(client):
    assert client.get("/healthz").status_code == 200


def test_api_requires_sign_in(client):
    assert client.get("/api/me").status_code == 401
    assert client.get("/").status_code == 401


def test_wrong_token_is_rejected(client):
    assert client.get("/login?token=wrong").status_code == 401


def test_viewer_sign_in(client):
    sign_in(client, "viewer")
    body = client.get("/api/me").get_json()
    assert body["role"] == "viewer"
    assert body["actionsEnabled"] is True


def test_admin_sign_in(client):
    sign_in(client, "admin")
    assert client.get("/api/me").get_json()["role"] == "admin"


def test_index_page_is_served_after_sign_in(client):
    sign_in(client, "viewer")
    response = client.get("/")
    assert response.status_code == 200
    assert b"DeployFlow dashboard" in response.data


def test_security_headers_are_set(client):
    sign_in(client, "viewer")
    response = client.get("/api/me")
    assert "default-src 'self'" in response.headers["Content-Security-Policy"]
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["Cache-Control"] == "no-store"


def test_unexpected_problems_come_back_as_readable_json(client, monkeypatch):
    sign_in(client, "viewer")

    def boom():
        raise RuntimeError("boom")

    monkeypatch.setattr(main.azure_api, "pipeline_ids", boom)
    response = client.get("/api/pipelines")
    assert response.status_code == 500
    assert "unexpected problem" in response.get_json()["error"].lower()


def test_viewer_cannot_start_actions(client, queued):
    sign_in(client, "viewer")
    response = client.post("/api/actions/rollback", json={"reason": "valid reason"}, headers=CSRF)
    assert response.status_code == 403
    assert queued == []


def test_actions_can_be_switched_off(client, queued, monkeypatch):
    monkeypatch.setattr(config, "ACTIONS_ENABLED", False)
    sign_in(client, "admin")
    response = client.post("/api/actions/rollback", json={"reason": "valid reason"}, headers=CSRF)
    assert response.status_code == 403
    assert queued == []


def test_missing_csrf_header_is_rejected(client, queued):
    sign_in(client, "admin")
    response = client.post("/api/actions/rollback", json={"reason": "valid reason"})
    assert response.status_code == 403
    assert queued == []


def test_invalid_reason_is_rejected(client, queued):
    sign_in(client, "admin")
    response = client.post("/api/actions/rollback", json={"reason": 'bad "quote"'}, headers=CSRF)
    assert response.status_code == 400
    assert queued == []


def test_valid_rollback_is_queued(client, queued):
    sign_in(client, "admin")
    response = client.post("/api/actions/rollback", json={"targetRevision": "", "reason": "Bad release"}, headers=CSRF)
    assert response.status_code == 200
    assert response.get_json()["runId"] == 99
    assert queued == [(7, {"targetRevision": "", "reason": "Bad release"})]


def test_deploy_request_needs_explicit_confirmation(client, queued):
    sign_in(client, "admin")
    assert client.post("/api/actions/deploy", json={}, headers=CSRF).status_code == 400
    response = client.post("/api/actions/deploy", json={"confirm": True}, headers=CSRF)
    assert response.status_code == 200
    assert queued == [(5, None)]