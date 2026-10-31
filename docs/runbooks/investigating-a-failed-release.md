# Runbook: investigating and resolving a failed release

## 1. What failed?

Open the `deployflow-cd` run in Azure DevOps and find the first red step.

| Failed step | Meaning | Production impact |
|---|---|---|
| Staging deploy or smoke test | The new image does not work in staging | None. The production stage never ran |
| Production: pre-traffic smoke test (outcome `aborted_before_traffic`) | The candidate revision was unhealthy before any user traffic | None |
| Production: canary step (outcome `rolled_back`) | The candidate breached error or latency limits and was rolled back automatically | Only the canary share, briefly |
| Production: `rollback_failed` | Automatic rollback could not be confirmed | Possible. Go to step 3 now |
| Final smoke test after promotion | The release is live but unhealthy | Yes. Go to step 3 now |

Download the artifact `promotion-production` and read `promotion-production.json`: `outcome`, `message`, `steps` (with measurements and breaches), `candidateRevision`, `previousRevision`.

## 2. Confirm the current state of production

```powershell
az containerapp ingress traffic show --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 -o table
az containerapp revision list --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 --query "[].{Revision:name, Active:properties.active, Traffic:properties.trafficWeight}" -o table
```

The revision with traffic 100 is what users get.

## 3. If users are affected, recover first

Run the `deployflow-rollback` pipeline (leave the target empty to go back one revision), approve it, and confirm the smoke test passes. Investigate afterwards.

## 4. Find the cause

Use the saved queries (run from the project folder):

```powershell
.\scripts\run-kql.ps1 -QueryFile .\monitoring\queries\01-request-overview.kql -AppName ca-deployflow-prod -Hours 6
.\scripts\run-kql.ps1 -QueryFile .\monitoring\queries\02-error-rate-over-time.kql -AppName ca-deployflow-prod -Hours 6
.\scripts\run-kql.ps1 -QueryFile .\monitoring\queries\05-unhealthy-revisions.kql -AppName ca-deployflow-prod -Hours 6
```

- Query 01 ties errors to a revision and a commit SHA. Open that commit on GitHub and read what changed.
- Query 02 shows when errors started: before or after a deployment?
- Query 05 shows probe failures, back-offs and image-pull problems.
- Query 06 (against the environment's own workspace) lists the deployment events, so you can line up the first error with the release time.
- Portal: Container Apps > `ca-deployflow-prod` > Monitoring > Log stream for live logs, and Metrics for `Requests` split by status code and revision.
- Application Insights `appi-deployflow-prod-eus2` > Investigate > Availability for outside-in availability.

## 5. Resolve

- Fix forward: a new commit goes through CI, staging, approval and the progressive release again.
- Never edit production by hand except to roll back traffic.

## 6. Afterwards

- Write a short incident note: what happened, how it was detected (alert, pipeline, user), time to detect, time to recover, root cause, follow-ups.
- Check the SLO error budget (`04-slo-and-error-budget.kql`).