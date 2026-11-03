# ADR 0008: Hosted dashboard, Entra sign-in and a read-only identity

## Status
Accepted

## Context
The dashboard must be reachable without the developer's laptop, require authentication, restrict actions by role, and never expose Azure credentials or pipeline tokens to the browser.

## Decision
- The dashboard runs as its own Container App in the shared environment (the free subscription allows one environment), in its own resource group, scaling from zero to a single replica.
- Sign-in uses Container Apps built-in authentication with Microsoft Entra ID (single tenant, redirect to login). Only `/healthz` is excluded so the platform and the pipeline can check health.
- The app trusts the sign-in headers set by that platform layer. Locally it uses one-time links instead.
- Roles: signed-in users are viewers; users listed in `DASHBOARD_ADMINS` are administrators. Actions are off unless `actions_enabled` is set in Terraform.
- A user-assigned managed identity reads Azure. It has Reader on the subscription and Log Analytics Reader on three workspaces. It has no write role on any application resource.
- It reads Azure DevOps as a service principal added to the organization in the project's Readers group. Queueing pipelines needs extra, per-pipeline permission, granted only if actions are enabled.
- The dashboard has its own pipeline: tests, security scans, a smoke test of the sign-in rules, an image scan and SBOM, and a deploy by digest.

## Consequences
- The platform-managed sign-in client secret expires after the period chosen in the Portal and must be renewed.
- Any member of the Entra tenant can sign in as a viewer. Restrict with "Assignment required" on the enterprise application if the tenant has other users.
- Other apps in the same Container Apps environment could reach the dashboard directly. This is acceptable here because only DeployFlow apps live in it.
- A single replica keeps the in-memory cache and rate limit simple.