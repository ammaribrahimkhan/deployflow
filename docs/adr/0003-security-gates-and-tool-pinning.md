# ADR 0003: Security gates and pinned scanner

## Status
Accepted

## Context
The pipeline must block releases on security problems and keep evidence of what was checked. In March 2026 a malicious Trivy release and re-pointed Docker tags (including `latest`) showed that a security tool is itself part of the supply chain.

## Decision
- Run Trivy from a Docker image pinned by digest, in one place (`pipelines/variables.yml`), with a persistent vulnerability database cache.
- Use several independent checks: Trivy for repository and image, pip-audit for Python dependencies, Bandit for code, Trivy config for Terraform.
- Gate on HIGH/CRITICAL findings that have a fix, so the build does not fail on problems nobody can fix yet.
- Generate a CycloneDX SBOM for every image and keep it with the build.
- Keep Azure credentials out of every step except the registry push.
- Defer image signing: it needs Key Vault and certificate management, so it is a later improvement.

## Consequences
- Updating the scanner is a deliberate change (new digest in one file), not an automatic one.
- First-time scans download a vulnerability database; later scans reuse the cache.
- The gate will occasionally fail because a new vulnerability was published, which is the intended behaviour. The fix is a dependency or base image update.