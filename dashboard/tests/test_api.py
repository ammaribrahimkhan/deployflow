import threading
import time

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

    monkeypatch.setattr(
        main.azure_api,
        "pipeline_ids",
        lambda: {
            "deployflow-rollback": 7,
            "deployflow-cd": 5,
        },
    )

    def fake_queue(pipeline_id, parameters):
        calls.append((pipeline_id, parameters))

        return {
            "id": 99,
            "_links": {
                "web": {
                    "href": "https://dev.azure.com/org/project/_build/results?buildId=99"
                }
            },
        }

    monkeypatch.setattr(main.azure_api, "queue_pipeline", fake_queue)

    return calls


def sign_in(client, role):
    response = client.get("/login?token=" + main.LOCAL_TOKENS[role])
    assert response.status_code == 302


def make_event(env, deployed_digest, scanned_digest="", gate="passed", time="2026-11-01T10:00:00Z"):
    """A deployment event as the dashboard normalises it."""
    return {
        "env": env,
        "time": time,
        "shortSha": "abc1234",
        "gateResult": gate,
        "criticalCount": 0,
        "highCount": 0,
        "trivyVersion": "0.73.0",
        "sbomSha256": "sbom123",
        "scannedImage": "",
        "scannedImageDigest": scanned_digest,
        "scannedImageReference": "",
        "imageDigest": deployed_digest,
    }


def fake_state(digest):
    """What read_app_state returns: Azure Resource Manager facts only."""
    return {
        "errors": [],
        "notes": [],
        "image": "registry/app@" + digest,
        "imageDigest": digest,
        "traffic": [],
        "revisions": [],
    }


def mock_security_sources(monkeypatch, events, staging_digest, production_digest):
    monkeypatch.setattr(
        main,
        "load_deployment_events",
        lambda: {"events": events, "problems": []},
    )

    states = {
        "staging": fake_state(staging_digest),
        "production": fake_state(production_digest),
    }

    monkeypatch.setattr(main, "read_app_state", lambda key: states[key])
    monkeypatch.setattr(main, "blocked_releases", lambda: [])


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


def test_serving_revision_is_the_one_that_receives_traffic():
    traffic = [{"revision": "app--b83-a1", "weight": 100}]

    assert main.pick_serving_revision(traffic, "app--0000003") == "app--b83-a1"
    assert main.pick_serving_revision([{"revision": "latest", "weight": 100}], "app--0000002") == "app--0000002"
    assert main.pick_serving_revision(
        [{"revision": "a", "weight": 10}, {"revision": "b", "weight": 90}],
        "x",
    ) == "b"
    assert main.pick_serving_revision([], "x") is None


def test_simultaneous_requests_share_one_calculation(client):
    calls = []

    def slow_loader():
        calls.append(1)
        time.sleep(0.2)
        return {"value": 1}

    results = []

    def worker():
        results.append(main.cached("shared-key", slow_loader))

    threads = [threading.Thread(target=worker) for _ in range(5)]

    for thread in threads:
        thread.start()

    for thread in threads:
        thread.join()

    assert len(calls) == 1
    assert len(results) == 5


def test_environment_shows_the_revision_that_serves_traffic(client, monkeypatch):
    sign_in(client, "viewer")

    monkeypatch.setattr(main.azure_api, "subscription_id", lambda: "sub")
    monkeypatch.setattr(main.azure_api, "get_token", lambda resource: "token")

    def fake_app(key):
        return {
            "properties": {
                "provisioningState": "Succeeded",
                "latestRevisionName": "ca--0000003",
                "configuration": {
                    "ingress": {
                        "fqdn": "ca.example.azurecontainerapps.io",
                        "traffic": [{"revisionName": "ca--b83-a1", "weight": 100}],
                    }
                },
                "template": {"containers": [{"image": "reg/app@sha256:aaa"}]},
            }
        }

    def fake_revisions(key):
        return [
            {
                "name": "ca--b83-a1",
                "properties": {
                    "createdTime": "2026-11-01T16:00:00Z",
                    "active": True,
                    "trafficWeight": 100,
                    "template": {"containers": [{"image": "reg/app@sha256:bbb"}]},
                },
            },
            {
                "name": "ca--0000003",
                "properties": {
                    "createdTime": "2026-11-02T01:00:00Z",
                    "active": True,
                    "trafficWeight": 0,
                    "template": {"containers": [{"image": "reg/app@sha256:ccc"}]},
                },
            },
        ]

    def fake_probe(url, timeout=20):
        if url.endswith("/health"):
            return {"ok": True, "status": 200, "ms": 100, "json": {"status": "healthy"}, "error": None}

        return {"ok": False, "status": 0, "ms": 30000, "json": None, "error": "timed out"}

    monkeypatch.setattr(main.azure_api, "container_app", fake_app)
    monkeypatch.setattr(main.azure_api, "container_app_revisions", fake_revisions)
    monkeypatch.setattr(main.azure_api, "probe", fake_probe)

    body = client.get("/api/environments").get_json()
    production = [item for item in body["environments"] if item["key"] == "production"][0]

    assert production["servingRevision"] == "ca--b83-a1"
    assert production["imageDigest"] == "sha256:bbb"
    assert production["live"]["infoOk"] is False
    assert production["live"]["infoError"] == "timed out"
    assert any("no traffic" in note for note in production["notes"])


def test_security_matches_the_scanned_image_digest(client, monkeypatch):
    sign_in(client, "viewer")

    events = [
        make_event("staging", "sha256:aaa111", scanned_digest="sha256:aaa111"),
    ]

    mock_security_sources(monkeypatch, events, "sha256:aaa111", "sha256:bbb222")

    response = client.get("/api/security")

    assert response.status_code == 200

    by_env = {item["env"]: item for item in response.get_json()["deployedImages"]}

    assert by_env["staging"]["verification"] == "MATCH"
    assert by_env["staging"]["matchedBy"] == "scanned image digest"
    assert by_env["staging"]["deployedImageScan"]["gateResult"] == "passed"
    assert by_env["production"]["verification"] == "UNVERIFIED"


def test_security_matches_older_records_by_the_deployed_digest(client, monkeypatch):
    sign_in(client, "viewer")

    # An older record: no scannedImageDigest, digest written in capitals and without the prefix.
    events = [
        make_event("production", "BBB222", scanned_digest=""),
    ]

    mock_security_sources(monkeypatch, events, "sha256:aaa111", "sha256:bbb222")

    response = client.get("/api/security")

    assert response.status_code == 200

    by_env = {item["env"]: item for item in response.get_json()["deployedImages"]}

    assert by_env["production"]["verification"] == "MATCH"
    assert "deployed image digest" in by_env["production"]["matchedBy"]
    assert by_env["staging"]["verification"] == "UNVERIFIED"


def test_security_is_unverified_when_nothing_matches(client, monkeypatch):
    sign_in(client, "viewer")

    events = [
        make_event("production", "sha256:other", scanned_digest="sha256:other"),
        make_event("staging", "sha256:another", gate=""),
    ]

    mock_security_sources(monkeypatch, events, "sha256:aaa111", "sha256:bbb222")

    response = client.get("/api/security")

    assert response.status_code == 200

    data = response.get_json()

    assert all(item["verification"] == "UNVERIFIED" for item in data["deployedImages"])
    assert data["scanHistory"][0]["deployedImageDigest"] == "sha256:other"


def test_viewer_cannot_start_actions(client, queued):
    sign_in(client, "viewer")

    response = client.post(
        "/api/actions/rollback",
        json={"reason": "valid reason"},
        headers=CSRF,
    )

    assert response.status_code == 403
    assert queued == []


def test_actions_can_be_switched_off(client, queued, monkeypatch):
    monkeypatch.setattr(config, "ACTIONS_ENABLED", False)

    sign_in(client, "admin")

    response = client.post(
        "/api/actions/rollback",
        json={"reason": "valid reason"},
        headers=CSRF,
    )

    assert response.status_code == 403
    assert queued == []


def test_missing_csrf_header_is_rejected(client, queued):
    sign_in(client, "admin")

    response = client.post(
        "/api/actions/rollback",
        json={"reason": "valid reason"},
    )

    assert response.status_code == 403
    assert queued == []


def test_invalid_reason_is_rejected(client, queued):
    sign_in(client, "admin")

    response = client.post(
        "/api/actions/rollback",
        json={"reason": 'bad "quote"'},
        headers=CSRF,
    )

    assert response.status_code == 400
    assert queued == []


def test_valid_rollback_is_queued(client, queued):
    sign_in(client, "admin")

    response = client.post(
        "/api/actions/rollback",
        json={
            "targetRevision": "",
            "reason": "Bad release",
        },
        headers=CSRF,
    )

    assert response.status_code == 200
    assert response.get_json()["runId"] == 99
    assert queued == [(7, {"targetRevision": "", "reason": "Bad release"})]


def test_deploy_request_needs_explicit_confirmation(client, queued):
    sign_in(client, "admin")

    assert client.post(
        "/api/actions/deploy",
        json={},
        headers=CSRF,
    ).status_code == 400

    response = client.post(
        "/api/actions/deploy",
        json={"confirm": True},
        headers=CSRF,
    )

    assert response.status_code == 200
    assert queued == [(5, None)]