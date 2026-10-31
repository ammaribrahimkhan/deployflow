# ADR 0007: Dashboard design and security

## Status
Accepted

## Context
The spec asks for a professional dashboard that shows real deployment, health, security and monitoring data, with authenticated and role-restricted actions, and without exposing Azure credentials or pipeline tokens to browser code.

## Decision
- A small Flask backend reads Azure Resource Manager, Log Analytics, Azure Monitor and Azure DevOps over plain HTTPS. No Azure SDK, so there are fewer dependencies to audit.
- The browser only ever talks to the dashboard backend. Azure tokens exist only on the server (Azure CLI sign-in on a laptop, managed identity in Azure).
- The frontend is React 18 with pinned, vendored files and no build step (no Node, no npm), served by the same backend with a strict Content Security Policy.
- Deployment history, rollback events and per-release security scan results come from the deployment events the release pipelines write to Application Insights. Request SLIs come from the request logs. Pipeline status comes from Azure DevOps.
- Every route needs a signed-in user. Roles are viewer and admin. Actions (queue a deployment, queue a rollback) are admin only, off by default, validated, rate limited, logged and protected by a custom request header and an Origin check.
- Actions only queue existing pipelines. The production approval and branch check in Azure DevOps still decide whether anything changes in production.

## Consequences
- The dashboard cannot show data that is not recorded: older releases have no scan result in their events.
- Results are cached for about 45 seconds to avoid hammering Azure.
- Locally, sign-in uses one-time links. Hosted in Azure (Milestone 8, second half), sign-in uses Microsoft Entra.