"""Cost and resource visibility for the DeployFlow dashboard (Milestone 9).

Honest by design:
- Actual cost comes from Azure Cost Management only when the subscription type and the identity
  allow it. That data is delayed by hours. It is never real time.
- Otherwise the page shows an ESTIMATE range calculated from the resources that exist and
  approximate public prices. It is labelled as an estimate and is not a billed amount.
"""
import threading
import time
from datetime import datetime, timedelta, timezone

from flask import Blueprint, jsonify

import azure_api
import config

blueprint = Blueprint("cost", __name__)

CACHE_SECONDS = 600
IDLE_DAYS = 7

# Resource groups that must never be removed by accident.
PROTECTED_GROUPS = {
    "rg-deployflow-tfstate-eus2",
    "rg-deployflow-shared-eus2",
    "rg-deployflow-prod-eus2",
}

COST_COLUMN_NAMES = ("PreTaxCost", "Cost", "PreTaxCostUSD", "CostUSD")

# Approximate monthly prices in USD: (label, low, high, note).
# These are ASSUMPTIONS for an order-of-magnitude estimate. Prices change and differ by region
# and offer: always check the Azure pricing pages and Cost analysis for the real numbers.
PRICE_ASSUMPTIONS = {
    "microsoft.containerregistry/registries": (
        "Container registry (assumed Basic tier)", 5.00, 5.00, "about 0.17 USD per day"),
    "microsoft.insights/webtests": (
        "Availability test (one location, every 15 minutes)", 1.44, 1.44, "about 2,880 runs x 0.0005 USD"),
    "microsoft.insights/scheduledqueryrules": (
        "Log search alert rule", 0.50, 3.00, "depends on how often it runs"),
    "microsoft.insights/metricalerts": (
        "Metric alert rule", 0.00, 0.50, "the first monitored time series are free"),
    "microsoft.operationalinsights/workspaces": (
        "Log Analytics workspace", 0.00, 3.00, "first 5 GB per month free, daily cap in place"),
    "microsoft.app/containerapps": (
        "Container app (scales to zero)", 0.00, 3.00, "free monthly grant, then billed per use"),
    "microsoft.app/managedenvironments": (
        "Container Apps environment (consumption plan)", 0.00, 0.00, "no fixed charge on the consumption plan"),
    "microsoft.storage/storageaccounts": (
        "Storage account (Terraform state)", 0.05, 0.50, "a few small blobs"),
}

REQUESTS_KQL = (
    "ContainerAppConsoleLogs_CL "
    f"| where TimeGenerated > ago({IDLE_DAYS}d) "
    "| where Log_s startswith '{' "
    "| extend j = parse_json(Log_s) "
    "| where isnotnull(j.status) "
    "| extend path = tostring(j.path) "
    "| where path !startswith '/health' "
    "| summarize requests = count(), lastRequest = max(TimeGenerated) by ContainerAppName_s"
)

_cache = {}
_cache_lock = threading.Lock()
_key_locks = {}


def cached(key, loader):
    """Reuse an answer for a few minutes. Simultaneous requests share one calculation."""
    with _cache_lock:
        item = _cache.get(key)

        if item and item[0] > time.time():
            return item[1]

        key_lock = _key_locks.setdefault(key, threading.Lock())

    with key_lock:
        with _cache_lock:
            item = _cache.get(key)

            if item and item[0] > time.time():
                return item[1]

        value = loader()

        with _cache_lock:
            _cache[key] = (time.time() + CACHE_SECONDS, value)

        return value


def _now():
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------- reading cost tables

def _table(properties):
    columns = properties.get("columns") or []
    names = [item.get("name") for item in columns]
    kinds = [item.get("type") for item in columns]

    return names, kinds, properties.get("rows") or []


def _cost_index(names, kinds):
    for index, name in enumerate(names):
        if name in COST_COLUMN_NAMES:
            return index

    for index, kind in enumerate(kinds):
        if kind == "Number" and names[index] != "UsageDate":
            return index

    return None


def parse_cost_rows(properties, group_column):
    """Return (groups, currency, total) from a Cost Management query result."""
    names, kinds, rows = _table(properties)
    cost_index = _cost_index(names, kinds)
    group_index = names.index(group_column) if group_column in names else None
    currency_index = names.index("Currency") if "Currency" in names else None

    groups = []
    total = 0.0
    currency = None

    if cost_index is None:
        return groups, currency, 0.0

    for row in rows:
        value = float(row[cost_index] or 0)
        total += value

        if currency_index is not None and row[currency_index]:
            currency = row[currency_index]

        if group_index is not None:
            groups.append(
                {
                    "name": row[group_index] or "(none)",
                    "cost": round(value, 2),
                }
            )

    groups.sort(key=lambda item: item["cost"], reverse=True)

    return groups, currency, round(total, 2)


def parse_daily_costs(properties):
    """Return [{date, cost}] oldest first from a daily Cost Management query result."""
    names, kinds, rows = _table(properties)
    cost_index = _cost_index(names, kinds)
    date_index = names.index("UsageDate") if "UsageDate" in names else None

    if cost_index is None or date_index is None:
        return []

    days = {}

    for row in rows:
        try:
            text = str(int(row[date_index]))
        except (TypeError, ValueError):
            continue

        label = text[0:4] + "-" + text[4:6] + "-" + text[6:8]
        days[label] = days.get(label, 0.0) + float(row[cost_index] or 0)

    return [
        {"date": day, "cost": round(days[day], 2)}
        for day in sorted(days)
    ]


# ---------------------------------------------------------------- Azure calls

def _cost_query(body):
    url = (
        "https://management.azure.com/subscriptions/"
        + azure_api.subscription_id()
        + "/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    )

    result = azure_api._request(
        "POST",
        url,
        azure_api.get_token(azure_api.RESOURCE_ARM),
        body,
        timeout=60,
    )

    return result.get("properties") or {}


def actual_costs():
    """Actual cost for this month so far. Raises ApiError when Azure does not allow it."""
    month = _cost_query(
        {
            "type": "ActualCost",
            "timeframe": "MonthToDate",
            "dataset": {
                "granularity": "None",
                "aggregation": {
                    "totalCost": {"name": "PreTaxCost", "function": "Sum"}
                },
                "grouping": [
                    {"type": "Dimension", "name": "ResourceGroupName"}
                ],
            },
        }
    )

    groups, currency, total = parse_cost_rows(month, "ResourceGroupName")

    daily = []
    daily_error = None

    try:
        now = datetime.now(timezone.utc)

        daily_properties = _cost_query(
            {
                "type": "ActualCost",
                "timeframe": "Custom",
                "timePeriod": {
                    "from": (now - timedelta(days=13)).strftime("%Y-%m-%dT00:00:00Z"),
                    "to": now.strftime("%Y-%m-%dT23:59:59Z"),
                },
                "dataset": {
                    "granularity": "Daily",
                    "aggregation": {
                        "totalCost": {"name": "PreTaxCost", "function": "Sum"}
                    },
                },
            }
        )

        daily = parse_daily_costs(daily_properties)

    except azure_api.ApiError as error:
        daily_error = error.message[:200]

    return {
        "currency": currency or "USD",
        "monthToDate": total,
        "byResourceGroup": groups,
        "daily": daily,
        "dailyError": daily_error,
    }


def list_resources():
    """Resource types that exist in the subscription (used for the estimate)."""
    path = "/subscriptions/" + azure_api.subscription_id() + "/resources"
    data = azure_api._arm_get(path, "2021-04-01")

    return [item.get("type") or "" for item in data.get("value", [])]


def list_budgets():
    path = (
        "/subscriptions/"
        + azure_api.subscription_id()
        + "/providers/Microsoft.Consumption/budgets"
    )

    data = azure_api._arm_get(path, "2023-05-01")
    budgets = []

    for item in data.get("value", []):
        properties = item.get("properties") or {}
        amount = properties.get("amount")
        spent = (properties.get("currentSpend") or {}).get("amount")

        budgets.append(
            {
                "name": item.get("name"),
                "amount": amount,
                "currentSpend": spent,
                "timeGrain": properties.get("timeGrain"),
                "percentUsed": (
                    round(100.0 * spent / amount, 1)
                    if amount and spent is not None
                    else None
                ),
            }
        )

    return budgets


def list_apps():
    path = (
        "/subscriptions/"
        + azure_api.subscription_id()
        + "/providers/Microsoft.App/containerApps"
    )

    return azure_api._arm_get(path, "2024-03-01").get("value", [])


def list_app_revisions(app_id):
    return azure_api._arm_get(app_id + "/revisions", "2024-03-01").get("value", [])


def list_resource_groups():
    path = "/subscriptions/" + azure_api.subscription_id() + "/resourcegroups"

    return azure_api._arm_get(path, "2021-04-01").get("value", [])


def request_rows():
    """Requests per app over the idle window, from the platform log workspace."""
    workspace = azure_api.workspace_customer_id(
        config.SHARED_RESOURCE_GROUP,
        config.PLATFORM_WORKSPACE,
    )

    rows = azure_api.log_query(workspace, REQUESTS_KQL)

    return {row.get("ContainerAppName_s"): row for row in rows}


# ---------------------------------------------------------------- calculations

def estimate_monthly(resource_types):
    """Estimate a monthly cost RANGE from the resources that exist. Not a billed amount."""
    counts = {}

    for name in resource_types:
        key = (name or "").lower()
        counts[key] = counts.get(key, 0) + 1

    lines = []
    low = 0.0
    high = 0.0

    for type_name, (label, per_low, per_high, note) in PRICE_ASSUMPTIONS.items():
        count = counts.get(type_name, 0)

        if not count:
            continue

        lines.append(
            {
                "label": label,
                "count": count,
                "lowUsd": round(per_low * count, 2),
                "highUsd": round(per_high * count, 2),
                "note": note,
            }
        )

        low += per_low * count
        high += per_high * count

    free_types = sorted(
        name for name in counts
        if name and name not in PRICE_ASSUMPTIONS
    )

    return {
        "lines": lines,
        "lowUsd": round(low, 2),
        "highUsd": round(high, 2),
        "freeTypes": free_types,
    }


def classify_app(app, revisions, request_row, requests_known):
    """Describe one container app: is it running, and does anything look idle or untidy?"""
    revision_props = [
        (item.get("name"), item.get("properties") or {})
        for item in revisions
    ]

    active = [(name, props) for name, props in revision_props if props.get("active")]
    replicas = sum(props.get("replicas") or 0 for _, props in active)
    without_traffic = [name for name, props in active if (props.get("trafficWeight") or 0) == 0]
    requests = int((request_row or {}).get("requests") or 0)

    flags = []

    if requests_known and requests == 0:
        flags.append(
            "No requests in the last "
            + str(IDLE_DAYS)
            + " days. Candidate to remove if you do not need it."
        )

    if without_traffic and len(active) > 1:
        flags.append(
            str(len(without_traffic))
            + " active revision(s) receive no traffic: "
            + ", ".join(without_traffic)
        )

    parts = (app.get("id") or "").split("/")

    return {
        "name": app.get("name"),
        "resourceGroup": parts[4] if len(parts) > 4 else "",
        "environment": (app.get("tags") or {}).get("environment"),
        "status": "running now" if replicas > 0 else "scaled to zero",
        "replicas": replicas,
        "activeRevisions": len(active),
        "requests": requests,
        "lastRequestAt": (request_row or {}).get("lastRequest"),
        "flags": flags,
    }


# ---------------------------------------------------------------- API

def build_cost_overview():
    result = {
        "source": "estimate",
        "currency": "USD",
        "actual": None,
        "actualError": None,
        "estimate": None,
        "estimateError": None,
        "budgets": [],
        "budgetError": None,
        "generatedAt": _now(),
    }

    try:
        result["actual"] = actual_costs()
        result["source"] = "actual"
        result["currency"] = result["actual"]["currency"] or "USD"
    except azure_api.ApiError as error:
        result["actualError"] = error.message[:300]

    try:
        result["estimate"] = estimate_monthly(list_resources())
    except azure_api.ApiError as error:
        result["estimateError"] = error.message[:300]

    try:
        result["budgets"] = list_budgets()
    except azure_api.ApiError as error:
        result["budgetError"] = error.message[:300]

    return result


def build_resources_overview():
    apps = list_apps()
    requests_by_app = {}
    requests_known = True
    request_error = None

    try:
        requests_by_app = request_rows()
    except azure_api.ApiError as error:
        requests_known = False
        request_error = error.message[:300]

    items = []

    for app in apps:
        try:
            revisions = list_app_revisions(app.get("id"))
        except azure_api.ApiError:
            revisions = []

        items.append(
            classify_app(
                app,
                revisions,
                requests_by_app.get(app.get("name")),
                requests_known,
            )
        )

    items.sort(key=lambda item: item["name"] or "")

    groups = []

    try:
        for group in list_resource_groups():
            name = group.get("name") or ""

            groups.append(
                {
                    "name": name,
                    "protected": name in PROTECTED_GROUPS,
                    "managedBy": (group.get("tags") or {}).get("managed_by"),
                }
            )
    except azure_api.ApiError:
        pass

    groups.sort(key=lambda item: item["name"])

    return {
        "apps": items,
        "resourceGroups": groups,
        "requestWindowDays": IDLE_DAYS,
        "requestError": request_error,
        "generatedAt": _now(),
    }


@blueprint.get("/api/cost")
def cost_overview():
    try:
        return jsonify(cached("cost", build_cost_overview))
    except azure_api.ApiError as error:
        return jsonify(error=error.message), 502


@blueprint.get("/api/resources")
def resources_overview():
    try:
        return jsonify(cached("resources", build_resources_overview))
    except azure_api.ApiError as error:
        return jsonify(error=error.message), 502