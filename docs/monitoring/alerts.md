# Alert inventory

All alerts notify the action group `ag-deployflow-ops` (email). Rules exist for staging (severity 3) and production (severity 1) unless noted. They resolve automatically when the condition clears.

| Alert | Type | Signal | Fires when | Why |
|---|---|---|---|---|
| `alert-<app>-5xx-errors` | Metric | Container Apps `Requests`, status category 5xx | More than 5 in 5 minutes | Application failures, fast |
| `alert-<app>-error-rate` | Log | Request logs (`ContainerAppConsoleLogs_CL`) | More than 5% of requests fail, with at least 10 requests in 10 minutes | Elevated error rate as a percentage |
| `alert-<app>-latency` | Metric | Container Apps `ResponseTime` (preview) | Average above 1000 ms over 15 minutes | Excessive latency |
| `alert-<app>-restarts` | Metric | Container Apps `RestartCount` | More than 3 restarts over 15 minutes | Crash loops |
| `alert-<app>-unhealthy-revision` | Log | System logs (`ContainerAppSystemLogs_CL`) | 3 or more probe failures, back-offs or image-pull problems in 10 minutes | Unhealthy revision |
| `alert-<app>-availability` | Metric | Application Insights availability percentage (production only) | Below 90% over 30 minutes | The app is not reachable from outside |
| `alert-deployflow-service-health` | Activity log | Azure Service Health | An incident affects East US 2 | Infrastructure issues outside our control |
| Failed pipeline runs | Azure DevOps notification | Build completed with status failed | Any pipeline in the project fails | Release and CI failures |

## Tuning

- Thresholds are Terraform variables in `infra/modules/alerts/variables.tf`.
- The availability test costs a small amount each month and keeps production warm. Turn it off with `enable_availability_test = false` in the prod stack.
- To test the latency alert, temporarily apply with `-var "latency_alert_threshold_ms=1"` and generate traffic; then apply again without the override.