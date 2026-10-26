# Security policy for the DeployFlow pipeline

## Gates

| Check | Tool | When it runs | Blocks the release when |
|---|---|---|---|
| Secrets and dependency vulnerabilities in the repository | Trivy (fs) | Every pull request and push | HIGH/CRITICAL vulnerability with a fix, or any HIGH/CRITICAL secret |
| Python dependencies, including indirect ones | pip-audit | Every pull request and push | Any known vulnerability |
| Static code analysis | Bandit | Every pull request and push | Medium severity or higher |
| Container image vulnerabilities | Trivy (image) | Pushes to main and manual runs | HIGH/CRITICAL vulnerability with a fix |
| Infrastructure misconfiguration | Trivy (config) | Infra pipeline | CRITICAL (HIGH is reported only) |
| Code quality | ruff | Every pull request and push | Any finding |

## Evidence kept for every released image

- SBOM (CycloneDX) and its SHA-256 hash
- Trivy JSON report and a summary (tool version, thresholds, counts, result)
- Release metadata: commit, build id, agent, image tag and digest, pipeline run URL
- Image labels with commit, build and source repository

## Exceptions

1. Prefer fixing: upgrade the dependency or base image.
2. If no fix is possible, add the ID to `.trivyignore` with an expiry date (`<ID> exp:YYYY-MM-DD`) and explain why in the pull request.
3. Exceptions are reviewed when they expire. An expired entry blocks the build again.

## Credentials

- Only the final "push to ACR" step has Azure credentials, through a service connection that uses workload identity federation (no stored secret).
- Scanning steps run without any Azure credentials.
- Pull request builds never log in to Azure.

## Not covered yet (known limitations)

- Image signing (planned: Notation with Azure Key Vault).
- Secret scanning of Git history (only current files are scanned).
- Vulnerabilities without a published fix are reported but do not block (`--ignore-unfixed`).
- Runtime threat detection.