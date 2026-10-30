"""DeployFlow sample workload: a tiny Flask API.

The pipeline injects release metadata (APP_VERSION, GIT_SHA, APP_ENV) so that
every log line and API response can be traced back to a specific commit.
Azure Container Apps adds CONTAINER_APP_REVISION, which says which revision answered.
"""
import json
import logging
import os
import random
import sys
import time
from datetime import datetime, timezone

from flask import Flask, g, jsonify, request

app = Flask(__name__)

STARTED_AT = datetime.now(timezone.utc)

# One JSON object per line on stdout: easy to query later in Log Analytics.
logger = logging.getLogger("deployflow")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False


def release_info():
    """Read release metadata from environment variables at call time."""
    return {
        "version": os.environ.get("APP_VERSION", "dev"),
        "gitSha": os.environ.get("GIT_SHA", "local"),
        "environment": os.environ.get("APP_ENV", "local"),
        "revision": os.environ.get("CONTAINER_APP_REVISION", "local"),
    }


def fault_percent():
    """Demo hook (chaos testing): percentage of requests to "/" that fail on purpose.

    0 (the default) means disabled. Only the release pipeline's demo switch sets it.
    """
    try:
        return float(os.environ.get("FAULT_INJECTION_PERCENT", "0"))
    except ValueError:
        return 0.0


@app.before_request
def start_timer():
    g.start = time.perf_counter()


@app.after_request
def log_request(response):
    if os.environ.get("LOG_REQUESTS", "true").lower() != "false":
        duration_ms = (time.perf_counter() - getattr(g, "start", time.perf_counter())) * 1000
        logger.info(
            json.dumps(
                {
                    "time": datetime.now(timezone.utc).isoformat(),
                    "method": request.method,
                    "path": request.full_path.rstrip("?"),
                    "status": response.status_code,
                    "durationMs": round(duration_ms, 2),
                    **release_info(),
                }
            )
        )
    return response


@app.get("/")
def index():
    percent = fault_percent()
    if percent > 0 and random.uniform(0, 100) < percent:  # nosec B311 - demo hook, not security related
        return jsonify(error="Injected fault (demo hook)"), 500
    return jsonify(
        service="deployflow-app",
        message="Hello from DeployFlow!",
        **release_info(),
    )


@app.get("/health")
def health():
    """Used by Azure probes, smoke tests and the dashboard. Never affected by the fault hook."""
    uptime = (datetime.now(timezone.utc) - STARTED_AT).total_seconds()
    return jsonify(
        status="healthy",
        uptimeSeconds=round(uptime),
        startedAt=STARTED_AT.isoformat(),
    )


@app.get("/api/info")
def info():
    return jsonify(
        startedAt=STARTED_AT.isoformat(),
        pythonVersion=sys.version.split()[0],
        **release_info(),
    )


@app.errorhandler(404)
def not_found(_error):
    return jsonify(error="Not found"), 404


@app.errorhandler(500)
def server_error(error):
    # Never leak stack traces to clients.
    logger.error(json.dumps({"level": "error", "message": str(error)}))
    return jsonify(error="Internal server error"), 500