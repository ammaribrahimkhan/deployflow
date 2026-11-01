"""Plain-HTTPS helpers for Azure Resource Manager, Log Analytics and Azure DevOps.

No Azure SDK is used on purpose: fewer dependencies to audit. Tokens come from the managed
identity when running in Azure, or from the Azure CLI sign-in when running on a laptop.
Tokens stay on the server; they are never sent to the browser.
"""
import json
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

import config

RESOURCE_ARM = "https://management.azure.com/"
RESOURCE_LOGS = "https://api.loganalytics.io/"
RESOURCE_DEVOPS = "499b84ac-1321-427f-aa17-267ca6975798"

_tokens = {}
_memo = {}


class ApiError(Exception):
    """A problem talking to Azure. `message` is safe to show to the user."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ---------------------------------------------------------------- tokens

def _token_from_managed_identity(resource):
    params = {"api-version": "2019-08-01", "resource": resource}
    client_id = os.environ.get("AZURE_CLIENT_ID")
    if client_id:
        params["client_id"] = client_id
    url = os.environ["IDENTITY_ENDPOINT"] + "?" + urllib.parse.urlencode(params)
    if not url.startswith(("http://localhost:", "http://127.0.0.1:")):
        raise ApiError(500, "Unexpected managed identity endpoint.")
    request = urllib.request.Request(
        url,
        headers={"X-IDENTITY-HEADER": os.environ["IDENTITY_HEADER"]},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:  # nosec B310
            return json.loads(response.read().decode("utf-8"))["access_token"]
    except (urllib.error.URLError, TimeoutError, OSError, ValueError, KeyError) as error:
        raise ApiError(
            500,
            "Could not get a token from the managed identity: " + str(error),
        ) from error


def _token_from_azure_cli(resource):
    az = shutil.which("az")
    if not az:
        raise ApiError(
            500,
            "The Azure CLI (az) was not found. Install it and run 'az login'.",
        )
    command = [
        az, "account", "get-access-token", "--resource", resource,
        "--query", "accessToken", "-o", "tsv",
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=90, check=False
        )  # nosec B603
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ApiError(500, "Could not run the Azure CLI: " + str(error)) from error
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        raise ApiError(
            401,
            "The Azure CLI could not get a token. Run 'az login'. "
            + result.stderr.strip()[:200],
        )
    return token


def get_token(resource):
    """Return a bearer token for the resource, reusing it for a while."""
    cached = _tokens.get(resource)
    now = time.time()
    if cached and cached[1] > now:
        return cached[0]
    if os.environ.get("IDENTITY_ENDPOINT") and os.environ.get("IDENTITY_HEADER"):
        token = _token_from_managed_identity(resource)
    else:
        token = _token_from_azure_cli(resource)
    _tokens[resource] = (token, now + 15 * 60)
    return token


# ---------------------------------------------------------------- HTTP

def _request(method, url, token, body=None, timeout=25):
    """Make an HTTPS JSON request and retain useful upstream diagnostics."""
    if not url.startswith("https://"):
        raise ApiError(500, "Refusing to call a URL that is not HTTPS.")

    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # nosec B310
            raw = response.read().decode("utf-8", errors="replace")
            final_url = response.geturl()
            content_type = response.headers.get("Content-Type", "unknown")
            host = urllib.parse.urlsplit(final_url).netloc

            if not raw.strip():
                return {}
            try:
                return json.loads(raw)
            except json.JSONDecodeError as error:
                preview = raw[:1000]
                raise ApiError(
                    502,
                    f"{method} {host} returned non-JSON data. "
                    f"Content-Type: {content_type}. "
                    f"Final URL: {final_url}. "
                    f"Response preview: {preview}",
                ) from error
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:2000]
        raise ApiError(
            error.code,
            f"{method} {error.url} returned HTTP {error.code}: {detail}",
        ) from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        host = urllib.parse.urlsplit(url).netloc
        raise ApiError(502, f"Could not reach {host}: {error}") from error


def probe(url, timeout=20):
    """Call a public URL of one of our own apps. Returns status, time and JSON body."""
    if not url.startswith("https://") or ".azurecontainerapps.io" not in url:
        return {
            "ok": False, "status": 0, "ms": 0, "json": None,
            "error": "Not an app URL",
        }
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:  # nosec B310
            raw = response.read(50000).decode("utf-8", "replace")
            status = response.status
    except urllib.error.HTTPError as error:
        return {
            "ok": False, "status": error.code,
            "ms": int((time.perf_counter() - started) * 1000),
            "json": None, "error": f"HTTP {error.code}",
        }
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        return {
            "ok": False, "status": 0,
            "ms": int((time.perf_counter() - started) * 1000),
            "json": None, "error": str(error),
        }
    elapsed = int((time.perf_counter() - started) * 1000)
    try:
        body = json.loads(raw)
    except ValueError:
        body = None
    return {
        "ok": status == 200, "status": status, "ms": elapsed,
        "json": body, "error": None,
    }


# ---------------------------------------------------------------- Azure Resource Manager

def _arm_get(path, api_version, extra_query=""):
    url = (
        "https://management.azure.com" + path
        + "?api-version=" + api_version + extra_query
    )
    return _request("GET", url, get_token(RESOURCE_ARM))


def subscription_id():
    if config.SUBSCRIPTION_ID:
        return config.SUBSCRIPTION_ID
    if "subscription" in _memo:
        return _memo["subscription"]
    data = _arm_get("/subscriptions", "2022-12-01")
    items = data.get("value", [])
    if len(items) != 1:
        raise ApiError(
            500,
            "Could not choose a subscription automatically. Set AZURE_SUBSCRIPTION_ID.",
        )
    _memo["subscription"] = items[0]["subscriptionId"]
    return _memo["subscription"]


def container_app_path(env_key):
    cfg = config.ENVIRONMENTS[env_key]
    return (
        f"/subscriptions/{subscription_id()}/resourceGroups/"
        f"{cfg['resource_group']}/providers/Microsoft.App/containerApps/{cfg['app']}"
    )


def container_app(env_key):
    return _arm_get(container_app_path(env_key), "2024-03-01")


def container_app_revisions(env_key):
    return _arm_get(
        container_app_path(env_key) + "/revisions", "2024-03-01"
    ).get("value", [])


def workspace_customer_id(resource_group, name):
    key = "workspace:" + resource_group + "/" + name
    if key in _memo:
        return _memo[key]
    path = (
        f"/subscriptions/{subscription_id()}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.OperationalInsights/workspaces/{name}"
    )
    data = _arm_get(path, "2022-10-01")
    customer_id = (data.get("properties") or {}).get("customerId")
    if not customer_id:
        raise ApiError(404, f"Workspace {name} has no customer id.")
    _memo[key] = customer_id
    return customer_id


def list_alerts():
    path = f"/subscriptions/{subscription_id()}/providers/Microsoft.AlertsManagement/alerts"
    extra = "&timeRange=7d&sortBy=lastModifiedDateTime&sortOrder=desc&pageCount=50"
    return _arm_get(path, "2019-05-05-preview", extra).get("value", [])


# ---------------------------------------------------------------- Log Analytics

def log_query(customer_id, kql):
    """Run a KQL query in a Log Analytics workspace and return dictionaries."""
    url = f"https://api.loganalytics.io/v1/workspaces/{customer_id}/query"
    result = _request(
        "POST", url, get_token(RESOURCE_LOGS), {"query": kql}, timeout=60
    )
    tables = result.get("tables") or []
    if not tables:
        return []
    columns = [column["name"] for column in tables[0]["columns"]]
    return [dict(zip(columns, row)) for row in tables[0]["rows"]]


# ---------------------------------------------------------------- Azure DevOps

def _devops_url(path, params):
    base = (
        f"https://dev.azure.com/{urllib.parse.quote(config.ORGANIZATION)}"
        f"/{urllib.parse.quote(config.PROJECT)}/_apis/"
    )
    return base + path + "?" + urllib.parse.urlencode(params)


def devops_get(path, params=None):
    query = dict(params or {})
    if path == "pipelines" or path.startswith("pipelines/"):
        query.setdefault("api-version", "7.1-preview.1")
    else:
        query.setdefault("api-version", "7.1")
    return _request(
        "GET",
        _devops_url(path, query),
        get_token(RESOURCE_DEVOPS),
    )


def devops_post(path, body):
    return _request(
        "POST",
        _devops_url(path, {"api-version": "7.1"}),
        get_token(RESOURCE_DEVOPS),
        body,
    )


def pipeline_ids():
    """Map pipeline name to pipeline id."""
    data = devops_get("pipelines")
    return {item["name"]: item["id"] for item in data.get("value", [])}


def recent_builds(definition_ids, top=40):
    params = {
        "definitions": ",".join(str(item) for item in definition_ids),
        "$top": top,
        "queryOrder": "queueTimeDescending",
    }
    return devops_get("build/builds", params).get("value", [])


def build_timeline(build_id):
    return devops_get(f"build/builds/{int(build_id)}/timeline")


def queue_pipeline(pipeline_id, template_parameters):
    """Start a run of a pipeline on main. ADO production approvals still apply."""
    body = {"resources": {"repositories": {"self": {"refName": "refs/heads/main"}}}}
    if template_parameters:
        body["templateParameters"] = template_parameters
    return devops_post(f"pipelines/{int(pipeline_id)}/runs", body)
