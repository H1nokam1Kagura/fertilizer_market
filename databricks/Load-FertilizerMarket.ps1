<#
.SYNOPSIS
    Load-FertilizerMarket.ps1 — One-shot loader. Optionally creates the Delta tables, then
    INSERT OVERWRITEs from local data/*.parquet.

.DESCRIPTION
    Use for:
      - First-time setup (-CreateTables)
      - Manual fallback when the weekly Databricks Job fails
      - Loading the Fairgrounds mirror (-Profile fairgrounds -Fairgrounds)

    Wraps every databricks CLI call in the 3× retry pattern. Pins --profile explicitly.

.PARAMETER DataDir
    Directory containing prices.parquet + use.parquet. Default: ..\data relative to script.

.PARAMETER Profile
    Databricks CLI profile name. Default: DEFAULT.

.PARAMETER Fairgrounds
    Target gates_open_data.open_data instead of ggo_agdev.bioinputs (use with -Profile fairgrounds).

.PARAMETER CreateTables
    Run the create_tables.sql DDL first.

.PARAMETER SkipLoad
    Run DDL only, skip the INSERT OVERWRITE. Useful first-time when data/*.parquet not yet built.

.EXAMPLE
    # First time on Azure:
    pwsh -File .\databricks\Load-FertilizerMarket.ps1 -CreateTables -SkipLoad

    # Routine manual fallback:
    pwsh -File .\databricks\Load-FertilizerMarket.ps1

    # Fairgrounds mirror:
    pwsh -File .\databricks\Load-FertilizerMarket.ps1 -CreateTables -Fairgrounds -Profile fairgrounds

.NOTES
    One-time setup:
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
      Unblock-File -Path <this script>
      databricks auth describe --profile DEFAULT
#>
[CmdletBinding()]
param(
    [string]$DataDir = (Join-Path $PSScriptRoot '..\data'),
    [string]$Profile = 'DEFAULT',
    [switch]$Fairgrounds,
    [switch]$CreateTables,
    [switch]$SkipLoad
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$catalog = if ($Fairgrounds) { 'gates_open_data' } else { 'ggo_agdev' }
$schema  = if ($Fairgrounds) { 'open_data'       } else { 'bioinputs'  }
$ddlFile = if ($Fairgrounds) { Join-Path $PSScriptRoot 'create_tables_fg.sql' } else { Join-Path $PSScriptRoot 'create_tables.sql' }

$DataDir = [System.IO.Path]::GetFullPath($DataDir)
$pricesParquet = Join-Path $DataDir 'prices.parquet'
$useParquet    = Join-Path $DataDir 'use.parquet'

# Staging path differs between workspaces — use a workspace-local /Volumes path
$stagingVolume = if ($Fairgrounds) { '/Volumes/gates_open_data/open_data/_staging' } else { '/Volumes/ggo_agdev/bioinputs/_staging' }

# ── PREFLIGHT ───────────────────────────────────────────────────────────────

Write-Host "[PREFLIGHT] catalog.schema = $catalog.$schema  profile=$Profile"
if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) { throw "databricks CLI not on PATH" }
if ($CreateTables -and -not (Test-Path $ddlFile)) { throw "DDL file not found: $ddlFile" }
if (-not $SkipLoad) {
    if (-not (Test-Path $pricesParquet)) { throw "missing $pricesParquet — run scripts/Refresh-FertilizerMarket.ps1 first or pass -SkipLoad" }
    if (-not (Test-Path $useParquet))    { throw "missing $useParquet — run scripts/Refresh-FertilizerMarket.ps1 first or pass -SkipLoad" }
}

# ── HELPERS ─────────────────────────────────────────────────────────────────

function Invoke-WithRetry {
    param([Parameter(Mandatory)][scriptblock]$Script, [int]$Max = 3, [int]$BackoffSec = 5, [string]$Label = '<unnamed>')
    for ($i = 1; $i -le $Max; $i++) {
        try { return & $Script }
        catch {
            if ($i -lt $Max) { Write-Warning "[$Label] attempt $i failed: $($_.Exception.Message). retry in ${BackoffSec}s"; Start-Sleep -Seconds $BackoffSec }
            else { throw }
        }
    }
}

function Invoke-DatabricksSQL {
    param([Parameter(Mandatory)][string]$Statement, [string]$Profile = 'DEFAULT', [string]$WarehouseId)
    $payload = @{ statement = $Statement; warehouse_id = $WarehouseId; wait_timeout = '30s'; on_wait_timeout = 'CONTINUE' } | ConvertTo-Json -Compress
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "dbxsql_$(Get-Random).json"
    [System.IO.File]::WriteAllText($tmp, $payload)
    try {
        Invoke-WithRetry -Label 'sql-submit' -Script {
            $raw = & databricks api post /api/2.0/sql/statements --profile $Profile --json "@$tmp" 2>&1
            $resp = $raw | Out-String | ConvertFrom-Json -ErrorAction Stop
            if (-not $resp.statement_id) { throw "no statement_id in: $raw" }
            $sid = $resp.statement_id
            for ($i = 0; $i -lt 60; $i++) {
                $poll = & databricks api get "/api/2.0/sql/statements/$sid" --profile $Profile 2>&1
                $pj = $poll | Out-String | ConvertFrom-Json -ErrorAction Stop
                $state = $pj.status.state
                if ($state -in 'SUCCEEDED','FAILED','CANCELED','CLOSED') {
                    if ($state -ne 'SUCCEEDED') { throw "statement $sid ended ${state}: $($pj.status.error.message)" }
                    return $pj
                }
                Start-Sleep -Seconds 2
            }
            throw "statement $sid timed out"
        }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-WarehouseId {
    param([string]$Profile)
    Invoke-WithRetry -Label 'warehouses-list' -Script {
        $raw = & databricks warehouses list --profile $Profile -o json 2>&1
        $list = $raw | Out-String | ConvertFrom-Json -ErrorAction Stop
        $running = $list | Where-Object { $_.state -in 'RUNNING','STARTING' } | Select-Object -First 1
        if (-not $running) { $running = $list | Select-Object -First 1 }
        if (-not $running) { throw "no warehouses on profile $Profile" }
        return $running.id
    }
}

# ── DDL ─────────────────────────────────────────────────────────────────────

$warehouseId = Get-WarehouseId -Profile $Profile
Write-Host "[WAREHOUSE] $warehouseId"

if ($CreateTables) {
    Write-Host "[DDL] running $ddlFile"
    $ddl = Get-Content $ddlFile -Raw
    # Split on semicolons but tolerate statements that span lines; the file uses ';\n' as separator
    $stmts = $ddl -split ';\s*\r?\n' | Where-Object { $_.Trim() }
    foreach ($s in $stmts) {
        Invoke-DatabricksSQL -Statement $s -Profile $Profile -WarehouseId $warehouseId | Out-Null
    }
    Write-Host "[DDL] $($stmts.Count) statement(s) executed"
}

# ── LOAD ────────────────────────────────────────────────────────────────────

if (-not $SkipLoad) {
    & databricks fs mkdir "dbfs:$stagingVolume" --profile $Profile 2>&1 | Out-Null

    Invoke-WithRetry -Label 'fs-cp-prices' -Script {
        & databricks fs cp $pricesParquet "dbfs:$stagingVolume/prices.parquet" --overwrite --profile $Profile
        if ($LASTEXITCODE -ne 0) { throw "fs cp prices failed" }
    }
    Invoke-WithRetry -Label 'fs-cp-use' -Script {
        & databricks fs cp $useParquet "dbfs:$stagingVolume/use.parquet" --overwrite --profile $Profile
        if ($LASTEXITCODE -ne 0) { throw "fs cp use failed" }
    }

    $sqlPrices = @"
INSERT OVERWRITE $catalog.$schema.fertilizer_price
SELECT source, source_record_id, country_iso3, country_name, product, product_grade,
       market_level, CAST(year AS INT) AS year, CAST(month AS INT) AS month,
       price_usd_per_t, price_local_per_t, currency, source_url, retrieved_at, review_flags
FROM read_files('$stagingVolume/prices.parquet', format => 'parquet')
"@
    $sqlUse = @"
INSERT OVERWRITE $catalog.$schema.fertilizer_use
SELECT source, source_record_id, country_iso3, country_name, state_or_region,
       CAST(year AS INT) AS year, nutrient, total_tonnes, kg_per_ha_arable, arable_land_ha,
       source_url, retrieved_at, review_flags
FROM read_files('$stagingVolume/use.parquet', format => 'parquet')
"@
    Write-Host "[LOAD] $catalog.$schema.fertilizer_price"
    Invoke-DatabricksSQL -Statement $sqlPrices -Profile $Profile -WarehouseId $warehouseId | Out-Null
    Write-Host "[LOAD] $catalog.$schema.fertilizer_use"
    Invoke-DatabricksSQL -Statement $sqlUse -Profile $Profile -WarehouseId $warehouseId | Out-Null
}

Write-Host "[DONE] $catalog.$schema.* loaded from $DataDir"
