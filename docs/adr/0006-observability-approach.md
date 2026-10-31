# ADR 0006: Observability with structured logs, platform metrics and Application Insights events

## Status
Accepted

## Context
We need request metrics, latency, failure rates, availability, alerts and a way to connect a release to what happened afterwards, on a free-tier budget, with strict supply-chain gates on dependencies and an unreliable home internet connection.

## Decision
- The app already writes one JSON log line per request (status, duration, commit SHA, version, revision). Container Apps sends it to Log Analytics. Queries on those logs give request metrics, latency percentiles, error rates and SLIs per revision and commit, with no new library.
- Alerts use Azure platform metrics where possible (fast and cheap) and log queries where a percentage or platform event is needed.
- Application Insights receives deployment and rollback events from the release pipelines (REST ingestion, no SDK, best effort) and runs a standard availability test on production.
- Alert rules, the action group and the availability test are Terraform modules, so staging and production are identical in structure.
- Failed pipeline runs notify by email through Azure DevOps notifications.
- Application Insights SDK / OpenTelemetry instrumentation is deferred.

## Consequences
- Logs reach Log Analytics a few minutes after they are written, so log alerts are slower than metric alerts.
- Latency measured in the app is server-side only; the availability test and the platform metric add an outside view.
- Adding the SDK later would give distributed traces and Application Map, at the cost of new dependencies that must pass the security gates.
- Deployment events are best effort: a failure to send never blocks a release.