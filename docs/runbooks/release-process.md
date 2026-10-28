# Release process (runbook)

## Normal release

1. Merge a pull request into `main`.
2. `deployflow-ci` runs: scans, tests, builds, scans the image, pushes it, and publishes `release-evidence`.
3. `deployflow-cd` starts by itself:
   - Staging stage: deploys the digest, runs the smoke test.
   - Production stage: waits for approval.
4. Before approving, open the run and check: the staging smoke test passed, and the commit and digest in `promotion-staging` are what you expect.
5. Click Review > Approve. Production deploys the same digest and runs the smoke test.

## If the staging smoke test fails

- The Production stage is skipped. Nothing reaches production.
- Open the `Smoke test staging` step log. The failure messages say what was wrong (not healthy, wrong commit, wrong environment, errors, latency).
- Check the staging app logs: Portal > Container Apps > `ca-deployflow-staging` > Monitoring > Log stream.
- Fix forward with a new commit, or rerun the pipeline if the failure was a cold start.

## If the production smoke test fails

- The Production stage is red. The previous revision name is in `promotion-production.json` (`previousRevision`).
- Until automatic rollback exists (Milestone 6), recover by hand:
  `az containerapp ingress traffic set --name ca-deployflow-prod --resource-group rg-deployflow-prod-eus2 --revision-weight <previousRevision>=100`
- Then investigate and fix forward.

## Rejecting a release

Click Review > Reject on the production stage. Production is untouched.