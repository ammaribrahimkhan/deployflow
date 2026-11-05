<#
Checks the repository before you share it. Run it from inside the repository:

  .\scripts\check-repo-hygiene.ps1

Errors (exit code 1): secret-like content, tracked state/plan/env/key files, missing required
documents, broken links, ADR numbering problems.
Warnings: things to check by eye (GUIDs, email addresses, personal paths, large files, TODO notes).
Use -Strict to treat warnings as errors.

Only files that git tracks are checked, so run `git add .` first.
#>
param([switch]$Strict)

$root = (git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $root) {
  Write-Host "Run this inside the git repository." -ForegroundColor Red
  exit 1
}
Set-Location $root

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Problem($list, $message) { $list.Add($message) }

$tracked = @(git ls-files)
if ($tracked.Count -eq 0) {
  Write-Host "git tracks no files. Run: git add ." -ForegroundColor Red
  exit 1
}

# 1. Required documents
$required = @(
  "README.md", ".gitignore", ".trivyignore",
  "docs/architecture.md",
  "docs/adr/README.md",
  "docs/demo/demo-scenarios.md",
  "docs/incidents/2026-11-01-noisy-unhealthy-revision-alert.md",
  "docs/screenshots/CHECKLIST.md",
  "docs/limitations-and-roadmap.md",
  "docs/portfolio/cv-and-interview.md",
  "docs/monitoring/alerts.md", "docs/monitoring/slos.md",
  "docs/runbooks/release-process.md", "docs/runbooks/investigating-a-failed-release.md", "docs/runbooks/teardown.md",
  "docs/security/security-policy.md", "docs/security/pipeline-identities.md",
  "docs/security/dashboard-identity.md", "docs/security/infra-pipeline-identity.md",
  "docs/cost/cost-and-resources.md"
)
foreach ($path in $required) {
  if ($tracked -notcontains $path) { Add-Problem $errors "Missing or not added to git: $path" }
}

# 2. Files that must never be committed
$forbidden = @(
  '\.tfstate($|\.)', '\.tfvars$', '(^|/)\.env($|\.)', '\.(pem|pfx|key|p12)$', '(^|/)id_(rsa|ed25519)',
  '(^|/)\.terraform/', '(^|/)tfplan$', '\.tfplan$', '(^|/)\.venv/', '(^|/)node_modules/', '(^|/)__pycache__/'
)
foreach ($path in $tracked) {
  foreach ($pattern in $forbidden) {
    if ($path -match $pattern) {
      Add-Problem $errors "File must not be committed: $path"
      break
    }
  }
}

# 3. Content scan
$skipExtensions = @(".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".gz", ".tar", ".woff", ".woff2", ".ttf", ".exe", ".dll", ".svg")
$skipPrefixes = @("dashboard/web/vendor/")
$selfPath = "scripts/check-repo-hygiene.ps1"

$blocking = @(
  @{ Name = "private key"; Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
  @{ Name = "AWS access key id"; Pattern = '\bAKIA[0-9A-Z]{16}\b' },
  @{ Name = "GitHub token"; Pattern = '\bgh[pousr]_[A-Za-z0-9]{30,}\b' },
  @{ Name = "Slack token"; Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}' },
  @{ Name = "JSON web token"; Pattern = '\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}' },
  @{ Name = "hard-coded secret value"; Pattern = '(?i)\b(password|passwd|client_secret|api[_-]?key|access[_-]?token)\b\s*[:=]\s*["''][^"''\s$%{(]{8,}["'']' }
)

$reviewOnly = @(
  @{ Name = "GUID (subscription, tenant or object id?)"; Pattern = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'; Ignore = '^0{8}-0{4}-0{4}-0{4}-0{12}$' },
  @{ Name = "email address"; Pattern = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'; Ignore = '@(example\.(com|org)|users\.noreply\.github\.com)$' },
  @{ Name = "personal Windows path"; Pattern = 'C:\\Users\\[A-Za-z0-9._-]+'; Ignore = '' }
)

$todoCount = 0

foreach ($path in $tracked) {
  if ($path -eq $selfPath) { continue }

  $skip = $false
  foreach ($prefix in $skipPrefixes) { if ($path.StartsWith($prefix)) { $skip = $true } }
  if ($skip) { continue }

  $extension = [System.IO.Path]::GetExtension($path).ToLower()
  if ($skipExtensions -contains $extension) { continue }

  $full = Join-Path $root $path
  if (-not (Test-Path $full)) { continue }

  $info = Get-Item $full
  if ($info.Length -gt 2MB) {
    Add-Problem $warnings ("Large file ({0:N1} MB): {1}" -f ($info.Length / 1MB), $path)
    continue
  }
  if ($info.Length -gt 1MB) { continue }

  $text = [System.IO.File]::ReadAllText($full)

  foreach ($rule in $blocking) {
    foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
      $line = ($text.Substring(0, $match.Index) -split "`n").Count
      Add-Problem $errors ("Possible {0} in {1} line {2}" -f $rule.Name, $path, $line)
    }
  }

  foreach ($rule in $reviewOnly) {
    foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
      if ($rule.Ignore -and $match.Value -match $rule.Ignore) { continue }
      $line = ($text.Substring(0, $match.Index) -split "`n").Count
      $shown = $match.Value
      if ($shown.Length -gt 10) { $shown = $shown.Substring(0, 6) + "..." }
      Add-Problem $warnings ("Check {0} in {1} line {2} ({3})" -f $rule.Name, $path, $line, $shown)
    }
  }

  $todoCount += [regex]::Matches($text, '\b(TODO|FIXME|XXX)\b').Count
}

if ($todoCount -gt 0) { Add-Problem $warnings "$todoCount TODO/FIXME/XXX note(s) in tracked files." }

# 4. Markdown links
$markdownFiles = @($tracked | Where-Object { $_ -like "*.md" })
foreach ($file in $markdownFiles) {
  $fullFile = Join-Path $root $file
  if (-not (Test-Path $fullFile)) { continue }

  $text = [System.IO.File]::ReadAllText($fullFile)
  $directory = Split-Path $file -Parent
  $base = $root
  if ($directory) { $base = Join-Path $root $directory }

  foreach ($match in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
    $target = $match.Groups[1].Value
    if ($target -match '^(https?:|mailto:|#)') { continue }

    $target = ($target -split '#')[0]
    if (-not $target) { continue }

    $resolved = [System.IO.Path]::GetFullPath((Join-Path $base $target))
    if (-not (Test-Path $resolved)) {
      $message = "Broken link in ${file}: $target"
      if ($target -match 'screenshots/') {
        Add-Problem $warnings "$message (add the screenshot or remove the row)"
      } else {
        Add-Problem $errors $message
      }
    }
  }
}

# 5. ADR numbering and index
$adrs = @($tracked | Where-Object { $_ -match '^docs/adr/\d{4}-.+\.md$' })
$numbers = @($adrs | ForEach-Object { [int]([regex]::Match($_, '^docs/adr/(\d{4})-').Groups[1].Value) } | Sort-Object)
for ($i = 0; $i -lt $numbers.Count; $i++) {
  if ($numbers[$i] -ne ($i + 1)) {
    Add-Problem $errors ("ADR numbering has a gap or a duplicate near {0:D4}." -f $numbers[$i])
    break
  }
}

$indexPath = Join-Path $root "docs/adr/README.md"
if (Test-Path $indexPath) {
  $index = [System.IO.File]::ReadAllText($indexPath)
  foreach ($adr in $adrs) {
    $name = Split-Path $adr -Leaf
    if ($index -notmatch [regex]::Escape($name)) { Add-Problem $errors "ADR not listed in docs/adr/README.md: $name" }
  }
}

# Result
Write-Host ""
Write-Host "Files checked: $($tracked.Count)"
Write-Host ""

if ($warnings.Count -gt 0) {
  Write-Host "WARNINGS ($($warnings.Count)): look at these yourself" -ForegroundColor Yellow
  $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
  Write-Host ""
}

if ($errors.Count -gt 0) {
  Write-Host "ERRORS ($($errors.Count)): fix these before sharing" -ForegroundColor Red
  $errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  exit 1
}

if ($Strict -and $warnings.Count -gt 0) {
  Write-Host "Strict mode: warnings count as errors." -ForegroundColor Red
  exit 1
}

Write-Host "Repository hygiene check passed." -ForegroundColor Green
exit 0