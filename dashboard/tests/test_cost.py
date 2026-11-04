import pytest

import config
import cost
import main
import server


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(config, "AUTH_MODE", "local")
    main._cache.clear()
    cost._cache.clear()
    server.app.config.update(TESTING=True)
    return server.app.test_client()


def sign_in(client):
    response = client.get("/login?token=" + main.LOCAL_TOKENS["viewer"])
    assert response.status_code == 302


def make_api_error(message):
    error = cost.azure_api.ApiError.__new__(cost.azure_api.ApiError)
    Exception.__init__(error, message)
    error.message = message
    error.status = 403
    return error


def make_app(name="ca-test"):
    return {
        "name": name,
        "id": "/subscriptions/s/resourceGroups/rg-test/providers/Microsoft.App/containerApps/" + name,
        "tags": {"environment": "test"},
        "properties": {"runningStatus": "Running"},
    }


def make_revision(name, active, replicas, weight):
    return {
        "name": name,
        "properties": {"active": active, "replicas": replicas, "trafficWeight": weight},
    }


def test_parse_cost_rows_groups_and_totals():
    properties = {
        "columns": [
            {"name": "PreTaxCost", "type": "Number"},
            {"name": "ResourceGroupName", "type": "String"},
            {"name": "Currency", "type": "String"},
        ],
        "rows": [[1.5, "rg-a", "USD"], [4.25, "rg-b", "USD"]],
    }

    groups, currency, total = cost.parse_cost_rows(properties, "ResourceGroupName")

    assert [group["name"] for group in groups] == ["rg-b", "rg-a"]
    assert currency == "USD"
    assert total == 5.75


def test_parse_daily_costs_merges_days_in_order():
    properties = {
        "columns": [
            {"name": "PreTaxCost", "type": "Number"},
            {"name": "UsageDate", "type": "Number"},
            {"name": "Currency", "type": "String"},
        ],
        "rows": [[0.5, 20261101, "USD"], [0.25, 20261102, "USD"], [0.25, 20261101, "USD"]],
    }

    assert cost.parse_daily_costs(properties) == [
        {"date": "2026-11-01", "cost": 0.75},
        {"date": "2026-11-02", "cost": 0.25},
    ]


def test_estimate_uses_resource_counts_and_lists_free_types():
    types = [
        "Microsoft.ContainerRegistry/registries",
        "Microsoft.Insights/webtests",
        "Microsoft.ManagedIdentity/userAssignedIdentities",
        "Microsoft.App/containerApps",
        "Microsoft.App/containerApps",
    ]

    result = cost.estimate_monthly(types)

    assert result["lowUsd"] > 0
    assert result["highUsd"] >= result["lowUsd"]
    assert any(line["count"] == 2 for line in result["lines"])
    assert "microsoft.managedidentity/userassignedidentities" in result["freeTypes"]


def test_classify_app_flags_idle_and_extra_revisions():
    revisions = [make_revision("r1", True, 1, 100), make_revision("r2", True, 0, 0)]

    item = cost.classify_app(make_app(), revisions, None, True)

    assert item["resourceGroup"] == "rg-test"
    assert item["status"] == "running now"
    assert any("No requests" in flag for flag in item["flags"])
    assert any("no traffic" in flag for flag in item["flags"])


def test_classify_app_is_not_idle_when_request_data_is_missing():
    item = cost.classify_app(make_app(), [make_revision("r1", True, 0, 100)], None, False)

    assert item["status"] == "scaled to zero"
    assert item["flags"] == []


def test_cost_endpoints_require_sign_in(client):
    assert client.get("/api/cost").status_code == 401
    assert client.get("/api/resources").status_code == 401


def test_cost_api_falls_back_to_an_estimate(client, monkeypatch):
    sign_in(client)

    def refused():
        raise make_api_error("not allowed")

    monkeypatch.setattr(cost, "actual_costs", refused)
    monkeypatch.setattr(cost, "list_resources", lambda: ["Microsoft.ContainerRegistry/registries"])
    monkeypatch.setattr(cost, "list_budgets", lambda: [])

    body = client.get("/api/cost").get_json()

    assert body["source"] == "estimate"
    assert "not allowed" in body["actualError"]
    assert body["estimate"]["lowUsd"] == 5.0


def test_cost_api_and_resources_api_return_data(client, monkeypatch):
    sign_in(client)

    monkeypatch.setattr(
        cost,
        "actual_costs",
        lambda: {"currency": "USD", "monthToDate": 3.21, "byResourceGroup": [], "daily": [], "dailyError": None},
    )
    monkeypatch.setattr(cost, "list_resources", lambda: [])
    monkeypatch.setattr(cost, "list_budgets", lambda: [])
    monkeypatch.setattr(cost, "list_apps", lambda: [make_app("ca-a")])
    monkeypatch.setattr(cost, "list_app_revisions", lambda app_id: [make_revision("r1", True, 0, 100)])
    monkeypatch.setattr(cost, "request_rows", lambda: {})
    monkeypatch.setattr(
        cost,
        "list_resource_groups",
        lambda: [
            {"name": "rg-deployflow-prod-eus2", "tags": {"managed_by": "terraform"}},
            {"name": "rg-other", "tags": None},
        ],
    )

    spend = client.get("/api/cost").get_json()

    assert spend["source"] == "actual"
    assert spend["actual"]["monthToDate"] == 3.21

    resources = client.get("/api/resources").get_json()
    protected = {group["name"]: group["protected"] for group in resources["resourceGroups"]}

    assert resources["apps"][0]["name"] == "ca-a"
    assert any("No requests" in flag for flag in resources["apps"][0]["flags"])
    assert protected["rg-deployflow-prod-eus2"] is True
    assert protected["rg-other"] is False