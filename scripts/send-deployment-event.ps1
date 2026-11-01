
<#
Records a deployment (or rollback) as a custom event in Application Insights.

- AppInsightsName : Application Insights resource name
- ResourceGroup   : Resource group
- RecordPath      : Deployment or rollback record JSON
- EnvironmentName : staging or production
- EventName       : Deployment or Rollback
- JobStatus       : Pipeline job status
- RunUrl          : Pipeline run URL
- MetadataPath    : CI release-metadata.json containing security scan results

Best effort: telemetry problems never fail a release.
#>

param(
    [Parameter(Mandatory = $true)] [string]$AppInsightsName,
    [Parameter(Mandatory = $true)] [string]$ResourceGroup,
    [Parameter(Mandatory = $true)] [string]$RecordPath,
    [Parameter(Mandatory = $true)] [string]$EnvironmentName,
    [string]$EventName = "Deployment",
    [string]$JobStatus = "",
    [string]$RunUrl = "",
    [string]$MetadataPath = ""
)

function Warn($message) {
    Write-Host "##vso[task.logissue type=warning]$message"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # ---------------------------------------------------------
    # 1. Read deployment record
    # ---------------------------------------------------------

    if (-not (Test-Path -LiteralPath $RecordPath)) {
        Warn "No deployment record found at: $RecordPath"
        exit 0
    }

    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json

    # Determine deployment outcome
    $outcome = $null

    if ($record.PSObject.Properties.Name -contains "outcome") {
        $outcome = [string]$record.outcome
    }

    if (-not $outcome) {
        if ($JobStatus -eq "Failed" -or $JobStatus -eq "Canceled") {
            $outcome = "failed"
        }
        elseif (
            $record.PSObject.Properties.Name -contains "alreadyDeployed" -and
            $record.alreadyDeployed -eq $true
        ) {
            $outcome = "already_deployed"
        }
        else {
            $outcome = "deployed"
        }
    }

    # ---------------------------------------------------------
    # 2. Read Application Insights connection information
    # ---------------------------------------------------------

    Write-Host "Reading Application Insights configuration..."

    $connectionString = (
        az resource show `
            --resource-group $ResourceGroup `
            --name $AppInsightsName `
            --resource-type "microsoft.insights/components" `
            --query "properties.ConnectionString" `
            -o tsv | Out-String
    ).Trim()

    $instrumentationKey = $null
    $endpoint = "https://dc.services.visualstudio.com/"

    if ($connectionString -match "InstrumentationKey=([^;]+)") {
        $instrumentationKey = $Matches[1]
    }

    if ($connectionString -match "IngestionEndpoint=([^;]+)") {
        $endpoint = $Matches[1]
    }

    if (-not $instrumentationKey) {
        $instrumentationKey = (
            az resource show `
                --resource-group $ResourceGroup `
                --name $AppInsightsName `
                --resource-type "microsoft.insights/components" `
                --query "properties.InstrumentationKey" `
                -o tsv | Out-String
        ).Trim()
    }

    if (-not $instrumentationKey) {
        Warn "Could not retrieve Application Insights instrumentation key."
        exit 0
    }

    if (-not $endpoint.EndsWith("/")) {
        $endpoint += "/"
    }

    # ---------------------------------------------------------
    # 3. Build event properties from deployment record
    # ---------------------------------------------------------

    $properties = [ordered]@{}

    foreach ($item in $record.PSObject.Properties) {
        $value = $item.Value

        if ($null -eq $value) {
            continue
        }

        if (
            $value -is [string] -or
            $value -is [int] -or
            $value -is [long] -or
            $value -is [double] -or
            $value -is [decimal] -or
            $value -is [bool]
        ) {
            $properties[$item.Name] = [string]$value
        }
    }

    $properties["environment"] = $EnvironmentName
    $properties["outcome"] = $outcome
    $properties["jobStatus"] = $JobStatus
    $properties["pipelineRunUrl"] = $RunUrl

    # ---------------------------------------------------------
    # 4. Read CI release metadata and security scan results
    # ---------------------------------------------------------

    Write-Host "DEBUG: MetadataPath = [$MetadataPath]"

    if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
        Warn "MetadataPath was not provided. Security metadata will be unavailable."
    }
    elseif (-not (Test-Path -LiteralPath $MetadataPath)) {
        Warn "Release metadata file does not exist: $MetadataPath"
    }
    else {
        try {
            Write-Host "DEBUG: Release metadata file exists."

            $meta = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json

            Write-Host "DEBUG: Release metadata JSON parsed successfully."

            if ($null -eq $meta.security) {
                Warn "Release metadata exists, but its security object is missing."
            }
            else {
                Write-Host "DEBUG: Security metadata successfully loaded."
                Write-Host "DEBUG: Trivy version = $($meta.security.toolVersion)"
                Write-Host "DEBUG: Gate result = $($meta.security.gateResult)"
                Write-Host "DEBUG: Critical count = $($meta.security.criticalCount)"
                Write-Host "DEBUG: High count = $($meta.security.highCount)"

                # Attach security scan information to the event.
                $properties["gateResult"] = [string]$meta.security.gateResult
                $properties["criticalCount"] = [string]$meta.security.criticalCount
                $properties["highCount"] = [string]$meta.security.highCount
                $properties["trivyVersion"] = [string]$meta.security.toolVersion
                $properties["sbomSha256"] = [string]$meta.security.sbomSha256
                $properties["scannedAtUtc"] = [string]$meta.security.scannedAtUtc

                if ($meta.security.scannedImage) {
                    $properties["scannedImage"] = [string]$meta.security.scannedImage
                }

if ($meta.security.scannedImageDigest) {
    $properties["scannedImageDigest"] = [string]$meta.security.scannedImageDigest
}

if ($meta.security.scannedImageReference) {
    $properties["scannedImageReference"] = [string]$meta.security.scannedImageReference
}

                if ($meta.security.severityThreshold) {
                    $properties["severityThreshold"] = [string]$meta.security.severityThreshold
                }

                if ($meta.security.sbomFormat) {
                    $properties["sbomFormat"] = [string]$meta.security.sbomFormat
                }

                Write-Host "DEBUG: Security properties added to deployment event."
            }

            if ($meta.buildNumber) {
                $properties["ciBuildNumber"] = [string]$meta.buildNumber
            }

            if ($meta.shortSha) {
                $properties["ciShortSha"] = [string]$meta.shortSha
            }
        }
        catch {
            Warn "Could not read security metadata: $($_.Exception.Message)"
        }
    }

    # ---------------------------------------------------------
    # 5. Add deployment measurements
    # ---------------------------------------------------------

    $measurements = [ordered]@{}

    if ($record.PSObject.Properties.Name -contains "steps") {
        $measurements["canarySteps"] = @($record.steps).Count
    }

    # ---------------------------------------------------------
    # 6. Build Application Insights event envelope
    # ---------------------------------------------------------

    Write-Host "DEBUG: Total event properties = $($properties.Count)"
    Write-Host "DEBUG: Security gate property present = $($properties.Contains('gateResult'))"

    $envelope = [ordered]@{
        name = "Microsoft.ApplicationInsights.Event"
        time = (Get-Date).ToUniversalTime().ToString("o")
        iKey = $instrumentationKey
        tags = [ordered]@{
            "ai.cloud.role" = "deployflow-release"
        }
        data = [ordered]@{
            baseType = "EventData"
            baseData = [ordered]@{
                ver          = 2
                name         = $EventName
                properties   = $properties
                measurements = $measurements
            }
        }
    }

    $json = $envelope | ConvertTo-Json -Depth 12 -Compress

    # ---------------------------------------------------------
    # 7. Send event with retries
    # ---------------------------------------------------------

    $uri = $endpoint + "v2/track"
    $sent = $false

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Sending Application Insights event (attempt $attempt of 3)..."

            $response = Invoke-RestMethod `
                -Uri $uri `
                -Method Post `
                -Body $json `
                -ContentType "application/json; charset=utf-8" `
                -TimeoutSec 20

            if ($response.itemsAccepted -ge 1) {
                $sent = $true
                break
            }

            Write-Host "Application Insights did not accept the event (attempt $attempt of 3)."
        }
        catch {
            Write-Host "Sending event failed (attempt $attempt of 3): $($_.Exception.Message)"
        }

        if ($attempt -lt 3) {
            Start-Sleep -Seconds (5 * $attempt)
        }
    }

    # ---------------------------------------------------------
    # 8. Final result
    # ---------------------------------------------------------

    if ($sent) {
        Write-Host "Deployment event '$EventName' recorded in $AppInsightsName."
        Write-Host "Environment: $EnvironmentName"
        Write-Host "Outcome: $outcome"

        if ($properties.Contains("gateResult")) {
            Write-Host "Security metadata: INCLUDED"
            Write-Host "Trivy gate: $($properties['gateResult'])"
        }
        else {
            Write-Host "Security metadata: NOT INCLUDED"
            Warn "Deployment event was sent without security metadata."
        }
    }
    else {
        Warn "Deployment event could not be sent to Application Insights. Release is not affected."
    }
}
catch {
    Warn "Deployment event step failed: $($_.Exception.Message). Release is not affected."
}

exit 0
