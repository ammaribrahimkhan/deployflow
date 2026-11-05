# Demo scenarios

Rehearse each scenario once before showing it. Scenarios 3 and 4 briefly break production on purpose: never run them without the intention to show them.

Set these once per terminal:

```powershell
cd $HOME\Documents\deployflow
az login
$prodFqdn = az containerapp show --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 --query properties.configuration.ingress.fqdn -o tsv
$stagingFqdn = az containerapp show --name ca-deployflow-staging --resource-group rg-deployflow-staging-eus2 --query properties.configuration.ingress.fqdn -o tsv
```

Keep the agent running (`cd C:\agent`, then `.\run.cmd`) and Docker Desktop open.

## Which scenarios for how much time

| Time | Show |
|---|---|
| 5 minutes | Scenario 3 (automatic rollback), then the dashboard |
| 10 minutes | Scenarios 2, 3 and 8 |
| 20 minutes | Scenarios 1, 2, 3, 4, then the dashboard and scenario 7 |

---

## Scenario 1: A normal release, start to finish (about 25 minutes)

**Shows:** secure CI, promotion by digest, approval, canary, evidence, dashboard verification. It is also the regression check that the tuned alert stays quiet.

1. Make a harmless change that still triggers CI:
```powershell
git checkout main
git pull
Add-Content app\README.md "`nLast demo release: $(Get-Date -Format yyyy-MM-dd)"
git add app\README.md
git commit -m "docs: demo release"
git push
```
2. Azure DevOps: `deployflow-ci` runs (about 5 to 12 minutes), then `deployflow-cd` starts by itself.
3. When Production waits, open the run, check the staging smoke test and the `promotion-staging` artifact, then **Review** > **Approve**.
4. Open the log of **Progressive release of the SAME digest**: pre-traffic smoke test, then steps at 10%, 50% and 100%, then `OUTCOME: promoted`.

**Expected:**
- Dashboard: staging and production show the new commit; deployment history shows two **Promoted** rows with the same digest; Security says **Verified** for both.
- Dashboard Alerts panel: **no new firing** during the release.
- `Invoke-RestMethod "https://$prodFqdn/api/info"` shows the new commit and revision.

**Say:** "CI builds and scans once. CD only promotes that exact digest, and the dashboard checks that the running digest is the scanned one."

## Scenario 2: The security gate blocks a vulnerable dependency (about 6 minutes)

**Shows:** shift-left security, nothing pushed, nothing deployed.

```powershell
git checkout -b demo/vulnerable-dependency
Add-Content app\requirements.txt "pyyaml==5.3"
git add app\requirements.txt
git commit -m "demo: add a vulnerable dependency"
git push -u origin demo/vulnerable-dependency
```

Open a pull request on GitHub from that branch. `deployflow-ci` starts for the pull request. If it does not, run `deployflow-ci` manually on that branch.

**Expected:**
- The **Test** stage fails at **Scan source for secrets and vulnerable dependencies (Trivy)**.
- The **BuildPush** stage never runs: no image is built or pushed.
- Dashboard Security panel, "Failed CI runs": the run appears as a **security gate** failure.

**Clean up:**
```powershell
git checkout main
git branch -D demo/vulnerable-dependency
git push origin --delete demo/vulnerable-dependency
```
Close the pull request on GitHub.

**Say:** "The gate is a hard stop. The scanner itself is pinned by digest so the gate cannot be swapped under me."

## Scenario 3: A bad release is rejected and rolled back automatically (about 10 minutes)

**Shows:** progressive delivery with automatic rollback, no human needed.

1. Azure DevOps > `deployflow-cd` > **Run pipeline**.
2. Tick **DEMO - redeploy to production even if this image is already live**.
3. Set **DEMO ONLY - percent of requests to "/" the candidate fails on purpose** to `100`. Leave everything else.
4. Run. Staging passes. Approve Production.

**Expected in the log:**
- The pre-traffic smoke test **passes** (it checks `/health` and `/api/info`, which the fault never touches).
- Step 1 (10%): `Candidate: 30 probes, 30 errors (100%)` and a warning `Canary step 1 FAILED`.
- `Restoring 100% of the traffic to the known-good revision`, a passing health check, then `OUTCOME: rolled_back`.
- The run is **red on purpose**.

**Verify:**
```powershell
az containerapp ingress traffic show --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 -o table
Invoke-RestMethod "https://$prodFqdn/"
```
The known-good revision holds 100% and `/` answers normally. The dashboard shows **Rejected, recovered automatically**.

**Say:** "Only the canary share of traffic ever saw the fault, for about a minute."

## Scenario 4: A bad release slips through, and the rollback pipeline recovers it (about 15 minutes)

**Shows:** manual recovery, idempotency, the approval on rollbacks.

1. `deployflow-cd` > **Run pipeline**. Tick the redeploy option, set the fault to `100`, **and** set **Production canary - maximum error rate (percent)** to `100`. Run and approve.
2. It **promotes**, because the limit cannot be exceeded. Confirm production is broken for `/`:
```powershell
try { Invoke-RestMethod "https://$prodFqdn/" } catch { $_.Exception.Response.StatusCode.value__ }
```
   You get `500`. (`/health` stays healthy, so availability is unaffected.)
3. `deployflow-rollback` > **Run pipeline**. Leave the target empty, reason `demo bad release`. Approve.
4. Verify `Invoke-RestMethod "https://$prodFqdn/"` works again.
5. Idempotency: run the rollback pipeline again with `targetRevision` set to the revision that is live now. The record says `noop_already_live`.

**Expected:** the dashboard shows **Recovered (manual rollback)**.

## Scenario 5: A real alert from a real fault in staging (about 20 minutes)

**Shows:** alerts, emails, resolution.

```powershell
az containerapp update --name ca-deployflow-staging --resource-group rg-deployflow-staging-eus2 --set-env-vars FAULT_INJECTION_PERCENT=100 --output none
.\scripts\generate-traffic.ps1 -BaseUrl "https://$stagingFqdn" -Requests 150 -DelayMs 500
.\scripts\generate-traffic.ps1 -BaseUrl "https://$stagingFqdn" -Requests 150 -DelayMs 500
```

**Expected:** every request returns `500`. The **5xx-errors** alert emails within a few minutes; the **error-rate** alert follows after the log delay.

**Restore and watch it resolve:**
```powershell
az containerapp update --name ca-deployflow-staging --resource-group rg-deployflow-staging-eus2 --set-env-vars FAULT_INJECTION_PERCENT=0 --output none
.\scripts\generate-traffic.ps1 -BaseUrl "https://$stagingFqdn" -Requests 100 -DelayMs 500
```
The dashboard Alerts panel shows the alerts firing, then **Resolved**. Investigate with `monitoring\queries\02-error-rate-over-time.kql` (see the failed release runbook).

## Scenario 6: A controlled infrastructure change (about 10 minutes)

**Shows:** plan, review, approval, safe apply.

1. `deployflow-infra-apply` > **Run pipeline** > stack `envs/prod`, **Apply unticked**. Expected: `0 to add, 0 to change, 0 to destroy` and "No changes": real infrastructure matches the code.
2. Show the approval gate refusing a change without applying it: edit the pipeline variable `dashboardAdmins` to add `demo@example.com`, run stack `envs/dashboard` with **Apply ticked**. The plan shows **1 to change** (the admin list). Open `infra-plan > plan.txt`, then **Reject** the approval. The Apply stage fails and nothing changes. Restore the variable.

**Say:** "Terraform applies only the saved plan I approved. If anything changed since, it refuses."

## Scenario 7: Cost and safe teardown (about 8 minutes)

**Shows:** honest cost, idle detection, protected resources.

1. Dashboard > **Cost, estimates and budget**: the notice says whether the figure is actual or an estimate, with the budget used.
2. Dashboard > **Resources**: running or scaled to zero, requests over 7 days, idle candidates, protected resource groups.
3. Teardown previews (these change nothing):
```powershell
.\scripts\teardown.ps1 -Stack prod
.\scripts\teardown.ps1 -Stack shared
```
   `prod` is refused by `prevent_destroy`. `shared` is refused because other stacks still exist.

## Scenario 8: Trace a running image back to its commit (about 5 minutes)

**Shows:** supply-chain traceability.

1. Dashboard > Deployment history: pick the latest production row and click **Run**.
2. In the CD run, open artifacts `promotion-production` and the CI run's `release-evidence`.
3. In `release-metadata.json` find `imageReference`, `gitSha` and the security result. Compare the digest with what is running:
```powershell
az containerapp revision list --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 --query "[?properties.trafficWeight==``100``].properties.template.containers[0].image" -o tsv
```
4. Dashboard Security panel: **Verified**, with the scanner version and SBOM hash.

**Say:** "From a running container I can reach the commit, the scan results and the SBOM, and the dashboard checks the link by digest."

## After a demo session

- Production should hold 100% on a healthy revision (`traffic show`).
- Staging fault is back to `0`.
- Pipeline variable `dashboardAdmins` is restored.
- Delete any demo branches.