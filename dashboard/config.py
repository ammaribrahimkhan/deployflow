"""Settings for the DeployFlow dashboard.

Every value has a default that matches this project. Environment variables override them.
Nothing in this file is a secret.
"""
import os


def _text(name, default=""):
    return os.environ.get(name, default).strip()


# Azure DevOps
ORGANIZATION = _text("DEVOPS_ORGANIZATION", "deployflow-ammar03")
PROJECT = _text("DEVOPS_PROJECT", "DeployFlow")

# Azure (empty = discovered automatically when the identity can see exactly one subscription)
SUBSCRIPTION_ID = _text("AZURE_SUBSCRIPTION_ID")

# Sign-in: "local" (one-time links, used on a laptop) or "easyauth" (Microsoft Entra, used in Azure)
AUTH_MODE = _text("DASHBOARD_AUTH_MODE", "local")

# Actions (queue a deployment or a rollback) are off unless this is "true"
ACTIONS_ENABLED = _text("DASHBOARD_ACTIONS_ENABLED", "false").lower() == "true"

# In "easyauth" mode these signed-in users (comma separated e-mail addresses) are administrators
ADMINS = {
    name.strip().lower()
    for name in _text("DASHBOARD_ADMINS").split(",")
    if name.strip()
}

# How long answers from Azure are reused, in seconds
CACHE_SECONDS = int(_text("DASHBOARD_CACHE_SECONDS", "45") or "45")

SHARED_RESOURCE_GROUP = "rg-deployflow-shared-eus2"
PLATFORM_WORKSPACE = "log-deployflow-shared-eus2"

PIPELINE_NAMES = {
    "ci": "deployflow-ci",
    "cd": "deployflow-cd",
    "rollback": "deployflow-rollback",
    "infra": "deployflow-infra-validate",
}

ENVIRONMENTS = {
    "staging": {
        "label": "Staging",
        "app": "ca-deployflow-staging",
        "resource_group": "rg-deployflow-staging-eus2",
        "app_insights": "appi-deployflow-staging-eus2",
        "workspace": "log-deployflow-staging-eus2",
        "app_env": "staging",
    },
    "production": {
        "label": "Production",
        "app": "ca-deployflow-prod",
        "resource_group": "rg-deployflow-prod-eus2",
        "app_insights": "appi-deployflow-prod-eus2",
        "workspace": "log-deployflow-prod-eus2",
        "app_env": "prod",
    },
}
