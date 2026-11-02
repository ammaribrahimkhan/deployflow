"""DeployFlow dashboard: a small Flask service that reads real data from Azure and Azure DevOps.

Security design:
- Azure tokens are used only on the server and are never sent to the browser.
- Every page and API call needs a signed-in user (local one-time links, or Microsoft Entra via
  Azure Container Apps authentication when hosted in Azure).
- Actions are admin only, switched off by default, protected against cross-site requests,
  validated, rate limited, logged, and still subject to the Azure DevOps production approval.
"""
import functools
import hmac
import json
import logging
import os
import secrets
import sys
import threading
import time
import urllib.parse
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from flask import Flask, g, jsonify, make_response, redirect, request, send_from_directory
from werkzeug.exceptions import HTTPException

import analysis
import azure_api
import config

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

app = Flask(__name__, static_folder=None)

logger = logging.getLogger("deployflow-dashboard")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

LOCAL_TOKENS = {
    "viewer": secrets.token_urlsafe(24),
    "admin": secrets.token_urlsafe(24),
}

OPEN_PATHS = {"/healthz", "/login"}
RATE_LIMIT = 3
RATE_WINDOW_SECONDS = 600
_rate_limit = {}

_cache = {}
_cache_lock = threading.Lock()
_key_locks = {}


def log_event(**fields):
    fields["time"] = datetime.now(timezone.utc).isoformat()
    logger.info(json.dumps(fields))


def cached(key, loader):
    """Reuse an answer for a few seconds.

    Requests that arrive at the same moment for the same key share ONE calculation
    instead of each repeating the same slow work.
    """
    now = time.time()

    with _cache_lock:
        item = _cache.get(key)
        if item and item[0] > now:
            return item[1]
        key_lock = _key_locks.setdefault(key, threading.Lock())

    with key_lock:
        with _cache_lock:
            item = _cache.get(key)
            if item and item[0] > time.time():
                return item[1]

        value = loader()

        with _cache_lock:
            _cache[key] = (time.time() + config.CACHE_SECONDS, value)

        return value


# ---------------------------------------------------------------- sign-in and security headers

def current_user():
    if config.AUTH_MODE == "easyauth":
        name = (
            request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME") or ""
        ).strip()

        if not name:
            return None

        role = "admin" if name.lower() in config.ADMINS else "viewer"
        return {"name": name, "role": role}

    cookie = request.cookies.get("df_session", "")

    if not cookie:
        return None

    for role, token in LOCAL_TOKENS.items():
        if hmac.compare_digest(
            cookie.encode("utf-8"),
            token.encode("utf-8"),
        ):
            return {"name": "local " + role, "role": role}

    return None


@app.before_request
def start_timer():
    g.started = time.perf_counter()
    return None


@app.before_request
def require_sign_in():
    if request.path in OPEN_PATHS:
        return None

    user = current_user()

    if user is None:
        if request.path.startswith("/api/"):
            return jsonify(error="You are not signed in."), 401

        return make_response(
            "You are not signed in. Open the sign-in link that was printed when the dashboard started.",
            401,
        )

    g.user = user
    return None


@app.after_request
def security_headers(response):
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"

    if request.path.startswith("/api/") or request.path == "/login":
        response.headers["Cache-Control"] = "no-store"

    if request.path.startswith("/api/"):
        elapsed = time.perf_counter() - getattr(
            g, "started", time.perf_counter()
        )

        log_event(
            event="request",
            method=request.method,
            path=request.path,
            status=response.status_code,
            ms=int(elapsed * 1000),
        )

    return response


def api_errors(handler):
    """Turn problems talking to Azure into a clear JSON error instead of a crash."""

    @functools.wraps(handler)
    def wrapper(*args, **kwargs):
        try:
            return handler(*args, **kwargs)

        except azure_api.ApiError as error:
            log_event(
                event="upstream_error",
                path=request.path,
                status=error.status,
                message=error.message[:200],
            )
            return jsonify(error=error.message), 502

    return wrapper


@app.errorhandler(Exception)
def unexpected_error(error):
    """Anything unexpected becomes a readable message; the terminal shows the details."""
    if isinstance(error, HTTPException):
        return error

    log_event(
        event="unexpected_error",
        path=request.path,
        error=type(error).__name__,
        message=str(error)[:300],
    )

    if request.path.startswith("/api/"):
        return jsonify(
            error=(
                "The dashboard hit an unexpected problem ("
                + type(error).__name__
                + "). Look at the terminal where it runs for details."
            )
        ), 500

    return make_response(
        "The dashboard hit an unexpected problem. Look at the terminal where it runs.",
        500,
    )


# ---------------------------------------------------------------- pages

@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/login")
def login():
    token = request.args.get("token", "")

    for role, expected in LOCAL_TOKENS.items():
        if (
            config.AUTH_MODE == "local"
            and token
            and hmac.compare_digest(
                token.encode("utf-8"),
                expected.encode("utf-8"),
            )
        ):
            response = redirect("/")
            response.set_cookie(
                "df_session",
                expected,
                httponly=True,
                samesite="Strict",
                secure=request.is_secure,
                max_age=8 * 3600,
            )
            log_event(event="sign_in", role=role)
            return response

    return make_response(
        "That sign-in link is not valid. Use the link printed when the dashboard started.",
        401,
    )


@app.get("/")
def index():
    return send_from_directory(WEB_DIR, "index.html")


@app.get("/static/<path:filename>")
def static_files(filename):
    return send_from_directory(WEB_DIR, filename)


@app.get("/api/me")
def me():
    return jsonify(
        user=g.user["name"],
        role=g.user["role"],
        authMode=config.AUTH_MODE,
        actionsEnabled=config.ACTIONS_ENABLED,
    )


# ---------------------------------------------------------------- environments

def _portal_link(resource_id, blade):
    return "https://portal.azure.com/#resource" + resource_id + blade


def pick_serving_revision(traffic, latest_revision):
    """The revision that receives the most traffic.

    In the traffic list, "latest" stands for the newest revision.
    """
    best_name = None
    best_weight = 0

    for item in traffic or []:
        weight = item.get("weight") or 0
        name = item.get("revision")

        if name == "latest":
            name = latest_revision

        if name and weight > best_weight:
            best_name = name
            best_weight = weight

    return best_name


def read_app_state(key):
    """Everything Azure Resource Manager says about one app. No call to the app itself."""

    def load():
        state = {
            "errors": [],
            "notes": [],
            "image": None,
            "imageTag": None,
            "imageDigest": None,
            "provisioningState": None,
            "runningStatus": None,
            "latestRevision": None,
            "servingRevision": None,
            "fqdn": None,
            "url": None,
            "traffic": [],
            "revisions": [],
        }

        try:
            details = azure_api.container_app(key)
            properties = details.get("properties") or {}

            ingress = (
                (properties.get("configuration") or {}).get("ingress") or {}
            )

            containers = (
                (properties.get("template") or {}).get("containers") or [{}]
            )

            image = containers[0].get("image", "")
            parts = analysis.image_parts(image)
            fqdn = ingress.get("fqdn")

            state.update(
                {
                    "image": image,
                    "imageTag": parts["tag"],
                    "imageDigest": parts["digest"],
                    "provisioningState": properties.get("provisioningState"),
                    "runningStatus": properties.get("runningStatus"),
                    "latestRevision": properties.get("latestRevisionName"),
                    "fqdn": fqdn,
                    "url": ("https://" + fqdn) if fqdn else None,
                    "traffic": [
                        {
                            "revision": item.get("revisionName") or "latest",
                            "weight": item.get("weight") or 0,
                        }
                        for item in (ingress.get("traffic") or [])
                    ],
                }
            )

        except azure_api.ApiError as error:
            state["errors"].append("Container App: " + error.message)

        # The image shown must belong to the revision that really receives traffic.
        try:
            revisions = azure_api.container_app_revisions(key)

            revisions.sort(
                key=lambda item: (
                    item.get("properties") or {}
                ).get("createdTime") or "",
                reverse=True,
            )

            revision_images = {}

            for item in revisions:
                props = item.get("properties") or {}

                revision_containers = (
                    (props.get("template") or {}).get("containers") or []
                )

                revision_images[item.get("name")] = (
                    revision_containers[0].get("image", "")
                    if revision_containers
                    else ""
                )

            weighted_traffic = [
                item
                for item in state["traffic"]
                if (item.get("weight") or 0) > 0
            ]

            serving_images = set()

            for item in weighted_traffic:
                revision_name = item.get("revision")

                if revision_name == "latest":
                    revision_name = state["latestRevision"]

                serving_image = revision_images.get(revision_name, "")

                if serving_image:
                    serving_images.add(serving_image)

            if len(serving_images) == 1:
                serving_image = next(iter(serving_images))
                serving_parts = analysis.image_parts(serving_image)

                state.update(
                    {
                        "image": serving_image,
                        "imageTag": serving_parts["tag"],
                        "imageDigest": serving_parts["digest"],
                    }
                )

            elif len(serving_images) > 1:
                state.update(
                    {
                        "image": "Multiple images currently receiving traffic",
                        "imageTag": None,
                        "imageDigest": None,
                    }
                )

            elif not weighted_traffic:
                state.update(
                    {
                        "image": None,
                        "imageTag": None,
                        "imageDigest": None,
                    }
                )

            state["revisions"] = [
                {
                    "name": item.get("name"),
                    "createdAt": (item.get("properties") or {}).get("createdTime"),
                    "active": (item.get("properties") or {}).get("active"),
                    "trafficWeight": (item.get("properties") or {}).get("trafficWeight"),
                    "health": (item.get("properties") or {}).get("healthState"),
                }
                for item in revisions[:6]
            ]

        except azure_api.ApiError as error:
            state["errors"].append("Revisions: " + error.message)

        serving = pick_serving_revision(state["traffic"], state["latestRevision"])
        state["servingRevision"] = serving

        latest = state["latestRevision"]

        if serving and latest and serving != latest:
            state["notes"].append(
                "A newer revision (" + latest + ") exists but receives no traffic, "
                "so it is not serving users."
            )

        return state

    return cached("app-state:" + key, load)


def probe_live(fqdn):
    """Check the running app. /health goes first because it also wakes a sleeping app."""
    base = "https://" + fqdn

    health = azure_api.probe(base + "/health", timeout=45)

    if not health["ok"]:
        return health, {
            "ok": False,
            "status": 0,
            "ms": 0,
            "json": None,
            "error": "skipped because /health did not answer",
        }

    info = azure_api.probe(base + "/api/info", timeout=30)

    if not info.get("json"):
        info = azure_api.probe(base + "/api/info", timeout=30)

    return health, info


def build_environment(key):
    cfg = config.ENVIRONMENTS[key]
    sub = azure_api.subscription_id()

    app_id = (
        f"/subscriptions/{sub}/resourceGroups/{cfg['resource_group']}"
        f"/providers/Microsoft.App/containerApps/{cfg['app']}"
    )

    insights_id = (
        f"/subscriptions/{sub}/resourceGroups/{cfg['resource_group']}"
        f"/providers/microsoft.insights/components/{cfg['app_insights']}"
    )

    workspace_id = (
        f"/subscriptions/{sub}/resourceGroups/{cfg['resource_group']}"
        f"/providers/Microsoft.OperationalInsights/workspaces/{cfg['workspace']}"
    )

    state = read_app_state(key)

    data = {
        "key": key,
        "label": cfg["label"],
        "app": cfg["app"],
        "resourceGroup": cfg["resource_group"],
        "errors": list(state["errors"]),
        "notes": list(state["notes"]),
        "links": {
            "app": _portal_link(app_id, "/overview"),
            "metrics": _portal_link(app_id, "/metrics"),
            "logs": _portal_link(app_id, "/logs"),
            "applicationInsights": _portal_link(insights_id, "/overview"),
            "workspace": _portal_link(workspace_id, "/logs"),
        },
        "image": state["image"],
        "imageTag": state["imageTag"],
        "imageDigest": state["imageDigest"],
        "provisioningState": state["provisioningState"],
        "runningStatus": state["runningStatus"],
        "latestRevision": state["latestRevision"],
        "servingRevision": state["servingRevision"],
        "url": state["url"],
        "traffic": list(state["traffic"]),
        "revisions": list(state["revisions"]),
    }

    fqdn = state["fqdn"]
    probe_ok = None

    if fqdn:
        health, info = probe_live(fqdn)

        probe_ok = bool(health["ok"])
        body = info.get("json") or {}

        data["live"] = {
            "healthOk": probe_ok,
            "healthMs": health["ms"],
            "gitSha": body.get("gitSha"),
            "version": body.get("version"),
            "environment": body.get("environment"),
            "revision": body.get("revision"),
            "infoOk": bool(info.get("json")),
            "infoError": info.get("error"),
            "checkedAt": datetime.now(timezone.utc).isoformat(),
            "error": health.get("error"),
        }

    data["status"] = analysis.release_status(
        probe_ok,
        state["traffic"],
        bool(state["errors"]) and not fqdn,
    )

    return data


def load_environments():
    def load():
        azure_api.subscription_id()
        azure_api.get_token(azure_api.RESOURCE_ARM)

        keys = list(config.ENVIRONMENTS.keys())

        with ThreadPoolExecutor(
            max_workers=min(4, max(1, len(keys)))
        ) as executor:
            results = list(
                executor.map(build_environment, keys)
            )

        return {"environments": results}

    return cached("environments", load)


@app.get("/api/environments")
@api_errors
def environments():
    return jsonify(load_environments())


# ---------------------------------------------------------------- pipelines

@app.get("/api/pipelines")
@api_errors
def pipelines():
    def load():
        ids = azure_api.pipeline_ids()

        wanted = {
            name: ids.get(name)
            for name in config.PIPELINE_NAMES.values()
        }

        missing = [
            name
            for name, identifier in wanted.items()
            if identifier is None
        ]

        builds = azure_api.recent_builds(
            [
                identifier
                for identifier in wanted.values()
                if identifier is not None
            ],
            60,
        )

        runs = [
            analysis.summarize_build(build)
            for build in builds
        ]

        return {
            "runs": runs[:30],
            "stats": analysis.build_stats(runs),
            "missingPipelines": missing,
        }

    return jsonify(cached("pipelines", load))


# ---------------------------------------------------------------- deployments

DEPLOYMENT_KQL = (
    "AppEvents "
    "| where TimeGenerated > ago(30d) "
    "| where Name in ('Deployment', 'Rollback') "
    "| extend p = Properties "
    "| project "
    "TimeGenerated, "
    "Name, "
    "outcome = tostring(p.outcome), "
    "shortSha = tostring(p.shortSha), "
    "appVersion = tostring(p.appVersion), "
    "revision = coalesce(tostring(p.candidateRevision), tostring(p.newRevision), tostring(p.targetRevision)), "
    "previousRevision = tostring(p.previousRevision), "
    "imageDigest = tostring(p.imageDigest), "
    "scannedImage = tostring(p.scannedImage), "
    "scannedImageDigest = tostring(p.scannedImageDigest), "
    "scannedImageReference = tostring(p.scannedImageReference), "
    "runUrl = coalesce(tostring(p.deploymentRunUrl), tostring(p.rollbackRunUrl), tostring(p.pipelineRunUrl)), "
    "gateResult = tostring(p.gateResult), "
    "criticalCount = tostring(p.criticalCount), "
    "highCount = tostring(p.highCount), "
    "trivyVersion = tostring(p.trivyVersion), "
    "sbomSha256 = tostring(p.sbomSha256) "
    "| order by TimeGenerated desc "
    "| take 100"
)


def load_deployment_events():
    def load():
        events = []
        problems = []

        for key, cfg in config.ENVIRONMENTS.items():
            try:
                customer_id = azure_api.workspace_customer_id(
                    cfg["resource_group"],
                    cfg["workspace"],
                )

                for row in azure_api.log_query(
                    customer_id,
                    DEPLOYMENT_KQL,
                ):
                    normalized_row = dict(row)
                    normalized_row["time"] = normalized_row.get(
                        "TimeGenerated"
                    )
                    normalized_row["name"] = normalized_row.get("Name")

                    events.append(
                        analysis.normalize_event(
                            normalized_row,
                            key,
                        )
                    )

            except azure_api.ApiError as error:
                problems.append(
                    f"{cfg['label']}: {error.message}"
                )

        events.sort(
            key=lambda item: item.get("time") or "",
            reverse=True,
        )

        return {
            "events": events,
            "problems": problems,
        }

    return cached("deployment-events", load)


@app.get("/api/deployments")
@api_errors
def deployments():
    loaded = load_deployment_events()
    events = loaded["events"]

    stats = {
        "all": analysis.deployment_stats(events)
    }

    for key in config.ENVIRONMENTS:
        stats[key] = analysis.deployment_stats(
            [
                item
                for item in events
                if item["env"] == key
            ]
        )

    # Show genuine failures and deployment attempts that were automatically
    # rolled back. Successful manual rollbacks are not failures.
    failures = [
        item
        for item in events
        if (
            item["kind"] == "failure"
            or item.get("autoRolledBack")
        )
    ][:20]

    return jsonify(
        events=events[:50],
        stats=stats,
        failures=failures,
        problems=loaded["problems"],
    )


# ---------------------------------------------------------------- security

def blocked_releases():
    def load():
        ids = azure_api.pipeline_ids()
        ci_id = ids.get(config.PIPELINE_NAMES["ci"])

        if ci_id is None:
            return []

        builds = azure_api.recent_builds([ci_id], 40)

        failed = [
            item
            for item in builds
            if item.get("result") == "failed"
        ][:8]

        if not failed:
            return []

        # Get the sign-in token once, before the parallel lookups.
        azure_api.get_token(azure_api.RESOURCE_DEVOPS)

        def describe(build):
            run = analysis.summarize_build(build)

            try:
                step = analysis.categorize_failed_step(
                    azure_api.build_timeline(build["id"])
                )

            except azure_api.ApiError:
                step = {
                    "name": "unknown",
                    "category": "unknown",
                }

            run["failedStep"] = step["name"]
            run["category"] = step["category"]

            return run

        with ThreadPoolExecutor(max_workers=4) as pool:
            return list(pool.map(describe, failed))

    return cached("blocked-releases", load)


def normalize_digest(value):
    """Lower-case a digest and drop the 'sha256:' prefix.

    Digests then compare equal however they were written.
    """
    if not isinstance(value, str):
        return ""

    text = value.strip().lower()

    if text.startswith("sha256:"):
        text = text[len("sha256:"):]

    return text


def security_scan_record(event, env_key):
    """Return the security evidence recorded for one deployment event."""
    return {
        "env": env_key,
        "label": config.ENVIRONMENTS[env_key]["label"],
        "time": event["time"],
        "shortSha": event["shortSha"],
        "gateResult": event["gateResult"],
        "criticalCount": event["criticalCount"],
        "highCount": event["highCount"],
        "trivyVersion": event["trivyVersion"],
        "sbomSha256": event["sbomSha256"],
        "scannedImage": event["scannedImage"],
        "scannedImageDigest": event["scannedImageDigest"],
        "scannedImageReference": event["scannedImageReference"],
        # The digest this release deployed. Older records have no scannedImageDigest,
        # but they still say which digest was deployed after the scan gate passed.
        "deployedImageDigest": event["imageDigest"],
    }


def find_scan_for_digest(records, live_digest):
    """Find the newest scan record that belongs to exactly this image digest.

    Records are newest first. Returns (record, how_it_matched) or (None, None).
    A scan belongs to an image, so records of every environment are searched.
    """
    if not live_digest:
        return None, None

    for scan in records:
        if normalize_digest(scan.get("scannedImageDigest")) == live_digest:
            return scan, "scanned image digest"

    for scan in records:
        if normalize_digest(scan.get("deployedImageDigest")) == live_digest:
            return scan, "deployed image digest (older record)"

    return None, None


@app.get("/api/security")
@api_errors
def security():
    events = load_deployment_events()["events"]

    all_records = [
        security_scan_record(event, event["env"])
        for event in events
        if event["gateResult"]
    ]

    all_records.sort(
        key=lambda item: item.get("time") or "",
        reverse=True,
    )

    deployed_images = []

    for key, cfg in config.ENVIRONMENTS.items():
        # Only Azure Resource Manager is asked here: no call to the running app.
        state = read_app_state(key)
        live_digest = normalize_digest(state.get("imageDigest"))

        env_records = [
            record for record in all_records
            if record["env"] == key
        ]

        latest_scan = env_records[0] if env_records else None

        matching_scan, matched_by = find_scan_for_digest(
            all_records,
            live_digest,
        )

        deployed_images.append(
            {
                "env": key,
                "label": cfg["label"],
                "liveImage": state.get("image"),
                "liveImageDigest": state.get("imageDigest"),
                "verification": "MATCH" if matching_scan else "UNVERIFIED",
                "matchedBy": matched_by,
                "deployedImageScan": matching_scan,
                "latestScan": latest_scan,
                "errors": state.get("errors", []),
            }
        )

    return jsonify(
        deployedImages=deployed_images,
        scanHistory=all_records[:100],
        latestScans=[
            item["latestScan"]
            for item in deployed_images
            if item["latestScan"] is not None
        ],
        blockedReleases=blocked_releases(),
    )


# ---------------------------------------------------------------- SLOs

def slo_kql(app_name):
    return (
        "let sloTarget = 99.0; let latencyTargetMs = 500.0; "
        "ContainerAppConsoleLogs_CL | where TimeGenerated > ago(30d) "
        f"| where ContainerAppName_s == '{app_name}' | where Log_s startswith '{{' "
        "| extend j = parse_json(Log_s) | where isnotnull(j.status) "
        "| extend status = toint(j.status), path = tostring(j.path), durationMs = todouble(j.durationMs) "
        "| where path !startswith '/health' "
        "| summarize total = count(), failed = countif(status >= 500), slow = countif(durationMs > latencyTargetMs) "
        "| extend availabilitySli = iff(total == 0, 100.0, round(100.0 * (total - failed) / total, 3)), "
        "latencySli = iff(total == 0, 100.0, round(100.0 * (total - slow) / total, 3)), "
        "budgetUsedPercent = iff(total == 0, 0.0, round(100.0 * failed / (total * (100.0 - sloTarget) / 100.0), 1)) "
        "| extend sloMet = availabilitySli >= sloTarget"
    )


AVAILABILITY_KQL = (
    "AppAvailabilityResults | where TimeGenerated > ago(30d) "
    "| summarize total = count(), passed = countif(tostring(Success) in ('true', 'True', '1'))"
)


@app.get("/api/slo")
@api_errors
def slo():
    def load():
        platform_id = azure_api.workspace_customer_id(
            config.SHARED_RESOURCE_GROUP,
            config.PLATFORM_WORKSPACE,
        )

        items = []

        for key, cfg in config.ENVIRONMENTS.items():
            entry = {
                "env": key,
                "label": cfg["label"],
                "requestSlo": None,
                "availability": None,
                "errors": [],
            }

            try:
                rows = azure_api.log_query(
                    platform_id,
                    slo_kql(cfg["app"]),
                )

                entry["requestSlo"] = rows[0] if rows else None

            except azure_api.ApiError as error:
                entry["errors"].append(
                    "Request logs: " + error.message
                )

            try:
                insights_id = azure_api.workspace_customer_id(
                    cfg["resource_group"],
                    cfg["workspace"],
                )

                rows = azure_api.log_query(
                    insights_id,
                    AVAILABILITY_KQL,
                )

                if rows and rows[0].get("total"):
                    total = rows[0]["total"]
                    passed = rows[0]["passed"]

                    entry["availability"] = {
                        "total": total,
                        "passed": passed,
                        "percent": round(
                            100.0 * passed / total,
                            3,
                        ),
                    }

            except azure_api.ApiError as error:
                entry["errors"].append(
                    "Availability test: " + error.message
                )

            items.append(entry)

        return {
            "windowDays": 30,
            "targets": {
                "requestSuccessPercent": 99.0,
                "latencyUnder500msPercent": 95.0,
                "availabilityPercent": 99.5,
            },
            "items": items,
        }

    return jsonify(cached("slo", load))


# ---------------------------------------------------------------- alerts

@app.get("/api/alerts")
@api_errors
def alerts():
    def load():
        result = []

        for item in azure_api.list_alerts():
            essentials = (
                (item.get("properties") or {}).get("essentials") or {}
            )

            rule = (
                essentials.get("alertRule") or ""
            ).rsplit("/", 1)[-1]

            if "deployflow" not in rule.lower():
                continue

            result.append(
                {
                    "rule": rule,
                    "severity": essentials.get("severity"),
                    "condition": essentials.get("monitorCondition"),
                    "state": essentials.get("alertState"),
                    "target": essentials.get("targetResourceName"),
                    "firedAt": essentials.get("startDateTime"),
                    "changedAt": essentials.get("lastModifiedDateTime"),
                    "description": (
                        essentials.get("description") or ""
                    )[:200],
                }
            )

        return {"alerts": result[:25]}

    return jsonify(cached("alerts", load))


# ---------------------------------------------------------------- actions

def action_guard():
    user = g.user

    if user["role"] != "admin":
        return jsonify(
            error="Only administrators can start actions."
        ), 403

    if not config.ACTIONS_ENABLED:
        return jsonify(
            error="Actions are switched off on this dashboard."
        ), 403

    if request.headers.get("X-DeployFlow-CSRF") != "1":
        return jsonify(error="Missing request header."), 403

    origin = request.headers.get("Origin")

    if (
        origin
        and urllib.parse.urlsplit(origin).netloc != request.host
    ):
        return jsonify(
            error="Cross-site requests are not allowed."
        ), 403

    now = time.time()

    recent = [
        stamp
        for stamp in _rate_limit.get(user["name"], [])
        if now - stamp < RATE_WINDOW_SECONDS
    ]

    if len(recent) >= RATE_LIMIT:
        return jsonify(
            error="Too many actions. Wait a few minutes."
        ), 429

    recent.append(now)
    _rate_limit[user["name"]] = recent

    return None


@app.post("/api/actions/rollback")
@api_errors
def action_rollback():
    blocked = action_guard()

    if blocked:
        return blocked

    clean, error = analysis.validate_rollback_request(
        request.get_json(silent=True)
    )

    if error:
        return jsonify(error=error), 400

    pipeline_id = azure_api.pipeline_ids().get(
        config.PIPELINE_NAMES["rollback"]
    )

    if pipeline_id is None:
        return jsonify(
            error="The rollback pipeline was not found."
        ), 404

    run = azure_api.queue_pipeline(
        pipeline_id,
        {
            "targetRevision": clean["targetRevision"],
            "reason": clean["reason"],
        },
    )

    url = analysis.safe_https(
        ((run.get("_links") or {}).get("web") or {}).get("href")
    )

    log_event(
        event="action",
        action="rollback",
        user=g.user["name"],
        target=clean["targetRevision"],
        reason=clean["reason"],
        runId=run.get("id"),
    )

    return jsonify(
        ok=True,
        runId=run.get("id"),
        url=url,
        message=(
            "Rollback requested. Approve the production check in Azure DevOps "
            "to let it run."
        ),
    )


@app.post("/api/actions/deploy")
@api_errors
def action_deploy():
    blocked = action_guard()

    if blocked:
        return blocked

    valid, error = analysis.validate_deploy_request(
        request.get_json(silent=True)
    )

    if not valid:
        return jsonify(error=error), 400

    pipeline_id = azure_api.pipeline_ids().get(
        config.PIPELINE_NAMES["cd"]
    )

    if pipeline_id is None:
        return jsonify(
            error="The CD pipeline was not found."
        ), 404

    run = azure_api.queue_pipeline(pipeline_id, None)

    url = analysis.safe_https(
        ((run.get("_links") or {}).get("web") or {}).get("href")
    )

    log_event(
        event="action",
        action="deploy",
        user=g.user["name"],
        runId=run.get("id"),
    )

    return jsonify(
        ok=True,
        runId=run.get("id"),
        url=url,
        message=(
            "Deployment requested. Staging runs first; approve the production "
            "check in Azure DevOps when you are ready."
        ),
    )


# ---------------------------------------------------------------- startup

def warm_up_tokens():
    """Fetch the three Azure sign-in tokens once, in the background, so the first page load is quicker."""
    for resource in (
        azure_api.RESOURCE_ARM,
        azure_api.RESOURCE_LOGS,
        azure_api.RESOURCE_DEVOPS,
    ):
        try:
            azure_api.get_token(resource)
        except azure_api.ApiError:
            pass


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8000"))

    threading.Thread(target=warm_up_tokens, daemon=True).start()

    if config.AUTH_MODE == "local":
        admin_link = (
            "http://127.0.0.1:%d/login?token=%s"
            % (port, LOCAL_TOKENS["admin"])
        )

        viewer_link = (
            "http://127.0.0.1:%d/login?token=%s"
            % (port, LOCAL_TOKENS["viewer"])
        )

        print("")
        print("DeployFlow dashboard (local mode)")
        print("  Admin sign-in link:  " + admin_link)
        print("  Viewer sign-in link: " + viewer_link)
        print("  Actions enabled: %s" % config.ACTIONS_ENABLED)
        print("")
        print("  Your browser opens by itself. Do NOT select text in this window:")
        print("  Windows pauses the program while text is selected (press Esc to resume).")
        print("  Stop the dashboard with Ctrl+C.")
        print("")

        if os.environ.get(
            "DASHBOARD_OPEN_BROWSER", "true"
        ).lower() == "true":
            threading.Timer(
                2.0,
                webbrowser.open,
                args=[admin_link],
            ).start()

    app.run(
        host="127.0.0.1",
        port=port,
        threaded=True,
        use_reloader=False,
    )