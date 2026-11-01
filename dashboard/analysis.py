"""Pure functions that turn raw Azure data into what the dashboard shows."""
import re
from datetime import datetime, timezone

SUCCESS_OUTCOMES = {"promoted", "deployed"}
NEUTRAL_OUTCOMES = {"already_live", "already_deployed", "noop_already_live"}
FAILURE_OUTCOMES = {
    "failed",
    "aborted_before_traffic",
    "failed_before_deploy",
    "failed_before_traffic",
    "rolled_back",
    "rollback_failed",
}
WARNING_OUTCOMES = {"promoted_with_cleanup_warning"}

_TIME = re.compile(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})")
REASON_PATTERN = re.compile(r"^[A-Za-z0-9 .,_:;()/\-]{3,100}$")
REVISION_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{2,99}$")


# ---------------------------------------------------------------- small helpers

def parse_time(text):
    if not text:
        return None
    match = _TIME.match(str(text))
    if not match:
        return None
    stamp = match.group(1) + " " + match.group(2)
    return datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)


def seconds_between(start, end):
    first = parse_time(start)
    second = parse_time(end)
    if first is None or second is None:
        return None
    return max(0, int((second - first).total_seconds()))


def safe_https(url):
    """Only let https links through to the browser."""
    if isinstance(url, str) and url.startswith("https://"):
        return url
    return ""


def _to_int(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- deployment events

def classify_event(event):
    """Return success, failure, rollback, neutral, warning or unknown."""
    if event.get("name") == "Rollback":
        return "rollback"
    outcome = (event.get("outcome") or "").lower()
    if outcome in SUCCESS_OUTCOMES:
        return "success"
    if outcome in FAILURE_OUTCOMES:
        return "failure"
    if outcome in NEUTRAL_OUTCOMES:
        return "neutral"
    if outcome in WARNING_OUTCOMES:
        return "warning"
    return "unknown"


def normalize_event(row, env_key):
    event = {
        "time": row.get("time"),
        "env": env_key,
        "name": row.get("name") or "",
        "outcome": (row.get("outcome") or "").strip(),
        "shortSha": row.get("shortSha") or "",
        "appVersion": row.get("appVersion") or "",
        "revision": row.get("revision") or "",
        "previousRevision": row.get("previousRevision") or "",
        "imageDigest": row.get("imageDigest") or "",
        "runUrl": safe_https(row.get("runUrl")),
        "gateResult": row.get("gateResult") or "",
        "criticalCount": _to_int(row.get("criticalCount")),
        "highCount": _to_int(row.get("highCount")),
        "trivyVersion": row.get("trivyVersion") or "",
        "sbomSha256": row.get("sbomSha256") or "",
    }
    event["kind"] = classify_event(event)
    event["autoRolledBack"] = (
        event["name"] == "Deployment" and event["outcome"] == "rolled_back"
    )
    return event


def deployment_stats(events):
    counts = {
        "success": 0, "failure": 0, "rollback": 0,
        "neutral": 0, "warning": 0, "unknown": 0,
    }
    automatic = 0
    for event in events:
        counts[event["kind"]] = counts.get(event["kind"], 0) + 1
        if event.get("autoRolledBack"):
            automatic += 1
    judged = counts["success"] + counts["failure"]
    rate = round(100.0 * counts["success"] / judged, 1) if judged else None
    return {
        "deployments": judged,
        "succeeded": counts["success"],
        "failed": counts["failure"],
        "rollbacks": counts["rollback"] + automatic,
        "automaticRollbacks": automatic,
        "manualRollbacks": counts["rollback"],
        "skipped": counts["neutral"],
        "warnings": counts["warning"],
        "successRatePercent": rate,
    }


# ---------------------------------------------------------------- pipeline runs

def summarize_build(build):
    definition = build.get("definition") or {}
    web = ((build.get("_links") or {}).get("web") or {}).get("href")
    status = build.get("status")
    if status == "completed":
        state = build.get("result") or "unknown"
    else:
        state = status or "unknown"
    branch = (build.get("sourceBranch") or "").replace("refs/heads/", "")
    return {
        "id": build.get("id"),
        "pipeline": definition.get("name"),
        "number": build.get("buildNumber"),
        "state": state,
        "branch": branch,
        "shortSha": (build.get("sourceVersion") or "")[:7],
        "reason": build.get("reason"),
        "queuedAt": build.get("queueTime"),
        "startedAt": build.get("startTime"),
        "finishedAt": build.get("finishTime"),
        "durationSeconds": seconds_between(
            build.get("startTime"), build.get("finishTime")
        ),
        "url": safe_https(web),
    }


def build_stats(runs):
    per_pipeline = {}
    for run in runs:
        item = per_pipeline.setdefault(
            run["pipeline"],
            {"succeeded": 0, "failed": 0, "other": 0, "durations": []},
        )
        if run["state"] in ("succeeded", "partiallySucceeded"):
            item["succeeded"] += 1
        elif run["state"] == "failed":
            item["failed"] += 1
        else:
            item["other"] += 1
        if (
            run["state"] in ("succeeded", "failed", "partiallySucceeded")
            and run["durationSeconds"] is not None
        ):
            item["durations"].append(run["durationSeconds"])

    by_pipeline = {}
    total_ok = 0
    total_bad = 0
    for name, item in per_pipeline.items():
        judged = item["succeeded"] + item["failed"]
        total_ok += item["succeeded"]
        total_bad += item["failed"]
        by_pipeline[name] = {
            "succeeded": item["succeeded"],
            "failed": item["failed"],
            "inProgressOrOther": item["other"],
            "successRatePercent": (
                round(100.0 * item["succeeded"] / judged, 1) if judged else None
            ),
            "averageDurationSeconds": (
                int(sum(item["durations"]) / len(item["durations"]))
                if item["durations"] else None
            ),
        }
    overall = total_ok + total_bad
    return {
        "byPipeline": by_pipeline,
        "overallSucceeded": total_ok,
        "overallFailed": total_bad,
        "overallSuccessRatePercent": (
            round(100.0 * total_ok / overall, 1) if overall else None
        ),
    }


# Words that identify a security check or a quality check by the name of the pipeline step.
# "scan" alone is NOT used: "Push scanned image to ACR" is a release step, not a security finding.
GATE_WORDS = (
    (
        "security gate",
        (
            "trivy",
            "scan source",
            "scan image",
            "scan terraform",
            "bandit",
            "static security",
            "pip-audit",
            "dependency audit",
            "secret",
        ),
    ),
    ("quality gate", ("ruff", "code quality", "unit test", "pytest", "lint")),
)


def categorize_failed_step(timeline):
    """Find the first failed task of a build and classify it."""
    records = (timeline or {}).get("records") or []
    failed = [
        item for item in records
        if item.get("type") == "Task" and item.get("result") == "failed"
    ]
    failed.sort(key=lambda item: item.get("order") or 0)
    if not failed:
        return {"name": "unknown", "category": "unknown"}
    name = failed[0].get("name") or "unknown"
    lowered = name.lower()
    for category, words in GATE_WORDS:
        if any(word in lowered for word in words):
            return {"name": name, "category": category}
    return {"name": name, "category": "build or release step"}


# ---------------------------------------------------------------- environments

def release_status(probe_ok, traffic, app_error):
    if app_error:
        return "unknown"
    weighted = [
        item for item in (traffic or []) if (item.get("weight") or 0) > 0
    ]
    if len(weighted) > 1:
        return "release in progress"
    if probe_ok:
        return "healthy"
    return "unreachable"


def image_parts(image):
    """Split 'registry/repo@sha256:abc' or 'registry/repo:tag' into parts."""
    if not image:
        return {"tag": None, "digest": None}
    if "@sha256:" in image:
        return {"tag": None, "digest": image.split("@", 1)[1]}
    last = image.rsplit("/", 1)[-1]
    if ":" in last:
        return {"tag": last.split(":", 1)[1], "digest": None}
    return {"tag": None, "digest": None}


# ---------------------------------------------------------------- input validation for actions

def validate_rollback_request(payload):
    """Return (clean_values, None) or (None, error_message)."""
    if not isinstance(payload, dict):
        return None, "The request body must be a JSON object."
    unknown = set(payload) - {"targetRevision", "reason"}
    if unknown:
        return None, "Unknown field(s): " + ", ".join(sorted(unknown))
    target = payload.get("targetRevision", "")
    reason = payload.get("reason", "")
    if target is None:
        target = ""
    if not isinstance(target, str) or not isinstance(reason, str):
        return None, "targetRevision and reason must be text."
    target = target.strip()
    reason = reason.strip()
    if target and not REVISION_PATTERN.match(target):
        return None, (
            "targetRevision must be a revision name "
            "(lower-case letters, digits and hyphens)."
        )
    if not REASON_PATTERN.match(reason):
        return None, (
            "reason must be 3 to 100 characters: letters, digits, "
            "spaces and . , _ : ; ( ) / - only."
        )
    return {"targetRevision": target, "reason": reason}, None


def validate_deploy_request(payload):
    if (
        not isinstance(payload, dict)
        or set(payload) != {"confirm"}
        or payload.get("confirm") is not True
    ):
        return False, 'Send exactly {"confirm": true} to request a deployment.'
    return True, None