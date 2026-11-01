import analysis


def test_classify_event_kinds():
    assert analysis.classify_event({"name": "Deployment", "outcome": "promoted"}) == "success"
    assert analysis.classify_event({"name": "Deployment", "outcome": "deployed"}) == "success"
    assert analysis.classify_event({"name": "Deployment", "outcome": "rolled_back"}) == "failure"
    assert analysis.classify_event({"name": "Deployment", "outcome": "aborted_before_traffic"}) == "failure"
    assert analysis.classify_event({"name": "Deployment", "outcome": "already_live"}) == "neutral"
    assert analysis.classify_event({"name": "Rollback", "outcome": "rolled_back"}) == "rollback"
    assert analysis.classify_event({"name": "Deployment", "outcome": "something-new"}) == "unknown"


def test_normalize_event_blocks_unsafe_urls_and_converts_numbers():
    row = {
        "time": "2026-11-01T10:00:00Z",
        "name": "Deployment",
        "outcome": "promoted",
        "runUrl": "javascript:alert(1)",
        "criticalCount": "0",
        "highCount": "2",
    }

    event = analysis.normalize_event(row, "production")

    assert event["runUrl"] == ""
    assert event["criticalCount"] == 0
    assert event["highCount"] == 2
    assert event["kind"] == "success"
    assert event["env"] == "production"


def test_normalize_event_preserves_scanned_image_metadata():
    row = {
        "time": "2026-11-01T10:00:00Z",
        "name": "Deployment",
        "outcome": "promoted",
        "scannedImage": "abc1234",
        "scannedImageDigest": "sha256:123456",
        "scannedImageReference": (
            "acr.azurecr.io/deployflow-app@sha256:123456"
        ),
    }

    event = analysis.normalize_event(row, "production")

    assert event["scannedImage"] == "abc1234"
    assert event["scannedImageDigest"] == "sha256:123456"
    assert event["scannedImageReference"] == (
        "acr.azurecr.io/deployflow-app@sha256:123456"
    )


def test_automatic_rollback_is_flagged():
    event = analysis.normalize_event(
        {"name": "Deployment", "outcome": "rolled_back"},
        "production",
    )

    assert event["autoRolledBack"] is True
    assert event["kind"] == "failure"


def test_deployment_stats_success_rate_and_rollbacks():
    events = [
        analysis.normalize_event({"name": "Deployment", "outcome": "promoted"}, "production"),
        analysis.normalize_event({"name": "Deployment", "outcome": "promoted"}, "production"),
        analysis.normalize_event({"name": "Deployment", "outcome": "promoted"}, "production"),
        analysis.normalize_event({"name": "Deployment", "outcome": "rolled_back"}, "production"),
        analysis.normalize_event({"name": "Rollback", "outcome": "rolled_back"}, "production"),
        analysis.normalize_event({"name": "Deployment", "outcome": "already_live"}, "production"),
    ]

    stats = analysis.deployment_stats(events)

    assert stats["deployments"] == 4
    assert stats["succeeded"] == 3
    assert stats["failed"] == 1
    assert stats["successRatePercent"] == 75.0
    assert stats["rollbacks"] == 2
    assert stats["automaticRollbacks"] == 1
    assert stats["manualRollbacks"] == 1
    assert stats["skipped"] == 1


def test_deployment_stats_without_events():
    stats = analysis.deployment_stats([])

    assert stats["successRatePercent"] is None
    assert stats["deployments"] == 0


def test_seconds_between_handles_azure_devops_timestamps():
    assert analysis.seconds_between(
        "2026-11-01T10:00:00.1234567Z",
        "2026-11-01T10:02:05.9Z",
    ) == 125

    assert analysis.seconds_between(
        None,
        "2026-11-01T10:02:05Z",
    ) is None


def test_summarize_build_states():
    finished = {
        "id": 1,
        "status": "completed",
        "result": "failed",
        "definition": {"name": "deployflow-ci"},
        "sourceBranch": "refs/heads/main",
        "sourceVersion": "1234567890abcdef",
        "startTime": "2026-11-01T10:00:00Z",
        "finishTime": "2026-11-01T10:05:00Z",
        "_links": {
            "web": {
                "href": "https://dev.azure.com/x"
            }
        },
    }

    running = {
        "id": 2,
        "status": "inProgress",
        "definition": {"name": "deployflow-cd"},
    }

    first = analysis.summarize_build(finished)
    second = analysis.summarize_build(running)

    assert first["state"] == "failed"
    assert first["branch"] == "main"
    assert first["shortSha"] == "1234567"
    assert first["durationSeconds"] == 300
    assert second["state"] == "inProgress"
    assert second["url"] == ""


def test_build_stats():
    runs = [
        {"pipeline": "deployflow-ci", "state": "succeeded", "durationSeconds": 100},
        {"pipeline": "deployflow-ci", "state": "failed", "durationSeconds": 50},
        {"pipeline": "deployflow-ci", "state": "inProgress", "durationSeconds": None},
    ]

    stats = analysis.build_stats(runs)

    assert stats["byPipeline"]["deployflow-ci"]["successRatePercent"] == 50.0
    assert stats["byPipeline"]["deployflow-ci"]["averageDurationSeconds"] == 75
    assert stats["overallSucceeded"] == 1
    assert stats["overallFailed"] == 1


def test_categorize_failed_step_security_and_quality():
    security = {
        "records": [
            {"type": "Task", "result": "succeeded", "order": 1, "name": "Checkout"},
            {
                "type": "Task",
                "result": "failed",
                "order": 2,
                "name": "Scan source for secrets and vulnerable dependencies (Trivy)",
            },
        ]
    }

    image_scan = {
        "records": [
            {
                "type": "Task",
                "result": "failed",
                "order": 1,
                "name": "Scan image with Trivy and generate SBOM",
            }
        ]
    }

    audit = {
        "records": [
            {
                "type": "Task",
                "result": "failed",
                "order": 1,
                "name": "Python dependency audit (pip-audit)",
            }
        ]
    }

    quality = {
        "records": [
            {
                "type": "Task",
                "result": "failed",
                "order": 1,
                "name": "Unit tests (pytest)",
            }
        ]
    }

    other = {
        "records": [
            {
                "type": "Task",
                "result": "failed",
                "order": 1,
                "name": "Build Docker image and smoke test",
            }
        ]
    }

    assert analysis.categorize_failed_step(security)["category"] == "security gate"
    assert analysis.categorize_failed_step(image_scan)["category"] == "security gate"
    assert analysis.categorize_failed_step(audit)["category"] == "security gate"
    assert analysis.categorize_failed_step(quality)["category"] == "quality gate"
    assert analysis.categorize_failed_step(other)["category"] == "build or release step"


def test_pushing_a_scanned_image_is_a_release_step_not_a_security_gate():
    timeline = {
        "records": [
            {
                "type": "Task",
                "result": "failed",
                "order": 1,
                "name": "Push scanned image to ACR and write release metadata",
            }
        ]
    }

    assert analysis.categorize_failed_step(timeline)["category"] == "build or release step"


def test_categorize_failed_step_without_failures():
    assert analysis.categorize_failed_step({"records": []})["category"] == "unknown"


def test_validate_rollback_request_accepts_good_input():
    clean, error = analysis.validate_rollback_request({
        "targetRevision": "ca-deployflow-prod--b12-a1",
        "reason": "Bad release (error spike)",
    })

    assert error is None
    assert clean["targetRevision"] == "ca-deployflow-prod--b12-a1"

    clean, error = analysis.validate_rollback_request({
        "targetRevision": "",
        "reason": "manual rollback",
    })

    assert error is None
    assert clean["targetRevision"] == ""


def test_validate_rollback_request_rejects_bad_input():
    assert analysis.validate_rollback_request({"reason": 'say "hi"'})[1] is not None
    assert analysis.validate_rollback_request({"reason": "ends with a backslash\\"})[1] is not None
    assert analysis.validate_rollback_request({
        "reason": "ok reason",
        "targetRevision": "Bad Revision!",
    })[1] is not None
    assert analysis.validate_rollback_request({
        "reason": "ok reason",
        "extra": "x",
    })[1] is not None
    assert analysis.validate_rollback_request("not an object")[1] is not None
    assert analysis.validate_rollback_request({"reason": "ab"})[1] is not None


def test_release_status():
    assert analysis.release_status(True, [{"weight": 100}], False) == "healthy"
    assert analysis.release_status(False, [{"weight": 100}], False) == "unreachable"
    assert analysis.release_status(True, [{"weight": 90}, {"weight": 10}], False) == "release in progress"
    assert analysis.release_status(None, [], True) == "unknown"


def test_image_parts():
    assert analysis.image_parts(
        "acr.azurecr.io/app@sha256:abc"
    )["digest"] == "sha256:abc"

    assert analysis.image_parts(
        "acr.azurecr.io/app:1a2b3c4"
    )["tag"] == "1a2b3c4"

    assert analysis.image_parts("")["tag"] is None