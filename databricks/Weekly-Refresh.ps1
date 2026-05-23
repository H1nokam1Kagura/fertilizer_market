<#
.SYNOPSIS
    Weekly-Refresh.ps1 — Databricks Job entrypoint. Pulls latest from Git folder, runs the
    refresh, pushes to Delta.

.DESCRIPTION
    Thin wrapper executed by the fertilizer-weekly-refresh Databricks Job every Sun 03:00 UTC.
    The repo is configured as a Databricks Git folder so the Job has access to the latest
    scripts/Refresh-FertilizerMarket.ps1.

    Fallback: if pwsh is not available on the Databricks serverless image, this notebook is
    replaced with a Python notebook that subprocess-execs pwsh. Detected on first scheduled run.

.NOTES
    Triggered by Databricks Job, not run manually. Manual fallback is Load-FertilizerMarket.ps1.
#>
[CmdletBinding()]
param(
    [string]$Profile = 'DEFAULT'
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (script lives in repo/databricks/)
$repoRoot = Split-Path -Parent $PSScriptRoot
$refresh  = Join-Path $repoRoot 'scripts/Refresh-FertilizerMarket.ps1'

if (-not (Test-Path $refresh)) { throw "refresh script not found at $refresh" }

# When running inside a Databricks Job, the Git folder mounts under /Workspace/Repos/...
# The data/ dir on that mount is read-only via the Git layer, so write outputs to a Volume.
$outDir  = '/Volumes/ggo_agdev/bioinputs/_staging'
$logPath = "$outDir/refresh_log.csv"

Write-Host "[WEEKLY] invoking $refresh -OutDir $outDir -LogPath $logPath -Profile $Profile"
pwsh -NoProfile -File $refresh -OutDir $outDir -LogPath $logPath -Profile $Profile
if ($LASTEXITCODE -ne 0) { throw "Refresh-FertilizerMarket.ps1 exited $LASTEXITCODE" }

Write-Host "[WEEKLY] success"
