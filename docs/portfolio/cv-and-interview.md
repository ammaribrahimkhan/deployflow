# CV and interview pack

## CV bullets (pick 4 to 6, keep each to two lines)

- Built **DeployFlow**, an end-to-end Azure DevOps release platform for a containerised Flask service: six YAML pipelines on a self-hosted agent, Terraform-managed Azure Container Apps, Container Registry, Log Analytics and Application Insights.
- Designed **supply-chain security gates**: Trivy (pinned by digest), Bandit, pip-audit and Ruff, CycloneDX SBOM per build, and promotion of the exact scanned image **by digest**; the image is pushed only if every gate passes.
- Implemented **progressive delivery with automatic rollback** (0%, 10%, 50%, 100% with error-rate and p95 checks) and an idempotent rollback pipeline; validated with fault-injection drills (3 canary releases rejected and recovered automatically, 4 manual rollbacks).
- Removed stored secrets: **workload identity federation** for pipelines, **managed identities** with least-privilege roles, and a **Microsoft Entra-protected** release dashboard with a read-only identity.
- Built **observability and SLOs**: structured request logs queried with KQL, alert rules, availability test, three SLOs with error budgets, and deployment events in Application Insights.
- Delivered a **React and Flask release dashboard** (pipelines, deployments, per-digest security verification, SLOs, alerts, cost) hosted on Container Apps, plus **cost visibility, budget alerts and an approval-gated Terraform pipeline** with protected teardown.

Re-check these numbers against your dashboard right before sending a CV. If you tune the unhealthy-revision alert result (incident action item 1), you may add a bullet such as: "Diagnosed noisy alerting (22 notifications in 28 hours during release testing) and fixed it by separating probe failures from crash signals", but only after you have verified it.

## LinkedIn summary (short)

I built DeployFlow to learn release engineering by doing it: a secured CI pipeline, promotion by image digest, approval-gated production releases with canary traffic and automatic rollback, Terraform infrastructure, SLOs and alerts, and a read-only release dashboard behind Microsoft Entra sign-in, all on a free Azure subscription with no stored credentials. The repository includes architecture decision records, runbooks, an incident report and a demo script.

## 90-second pitch

"DeployFlow is a release platform I built on Azure DevOps. A pull request runs security scans and tests. After merge, CI builds the image once, scans it, creates an SBOM and pushes it only if every gate passes. CD then promotes that exact digest to staging and, after a manual approval, to production. Production releases start at zero percent traffic and move to 10, 50 and 100, checking error rate and latency each time, and roll back by themselves if a limit is breached. Everything is Terraform, with an approval-gated apply pipeline. A dashboard behind Entra sign-in shows what is running, whether the running image is the scanned one, SLOs, alerts and cost. I tested the safety features with deliberate fault injection and wrote up what I learned, including a noisy alert I had to fix."

## Questions you will be asked

**Why Container Apps and not Kubernetes?**
Revisions, traffic splitting and scale to zero are built in, and AKS would add cost and operational weight that does not teach the release engineering I wanted to show. The trade-off is less control.

**How do you make sure an unscanned image never reaches production?**
CI pushes only after every gate passes. CD reads the release metadata, requires a passed gate and a build from `main`, deploys by digest, and refuses a digest that differs from the one verified in staging. The dashboard then re-checks the scan evidence for the running digest.

**What does your rollback not catch?**
Anything the synthetic probes cannot see: subtle logic or data bugs and regional problems. Rolling back code also does not roll back data, so migrations must be expand and contract.

**How do you handle secrets?**
Pipelines use workload identity federation and apps use managed identities, so there are no stored passwords. The one secret is the platform-managed Entra client secret for dashboard sign-in, which expires and must be renewed. Trivy secret scanning and a hygiene script guard the repository.

**What was the hardest bug?**
Two stand out. The dashboard showed the wrong serving revision and blank fields after a cold start: probes timed out and the code fell back to the newest revision. I derived the serving revision from the traffic split, probed health first, retried, and shared one calculation between simultaneous requests. Second, a noisy alert: see the incident report.

**Why one shared Container Apps environment?**
The free subscription allows one. I isolated by app, resource group, identity and role scope, and documented the blast-radius trade-off in an ADR.

**Why a self-hosted agent?**
Free-tier pipeline limits and the need for Docker and Trivy. The cost is a laptop dependency and a trust boundary I have to protect. On the roadmap: ephemeral agents.

**How do you test infrastructure changes?**
Format check, validate, Trivy config scan, a plan-only run to detect drift, and an apply that uses the saved, approved plan. The plan stage blocks deletion of protected resources.

**How do you know what it costs?**
Actual cost from Cost Management when the subscription exposes it; otherwise a labelled range from assumed prices. Plus a budget with alerts and idle detection. I never present an estimate as a bill.

**What would you change to run this for a team?**
Ephemeral agents, split plan and apply identities, branch protection with required reviews, real-traffic SLO gates, private networking, and multiple regions.

**Why do SLOs look so good?**
Traffic is mostly synthetic and low. They demonstrate the method, not production reliability.

**What does the SBOM give you?**
An inventory per image to answer "are we affected?" quickly when a vulnerability is published. Its hash is recorded in the deployment event so a release can be tied to its inventory.

## Claims to avoid

- "Production-grade", "highly available" or "multi-region".
- Any reliability or cost figure presented as real user or billing data.
- That the fault-injection failures were real incidents. They were drills.
- That the unhealthy-revision fix is proven, until you have run action item 1.