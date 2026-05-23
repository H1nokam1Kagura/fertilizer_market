<#
.SYNOPSIS
    Refresh-FertilizerMarket.ps1 — Pull fertilizer price + use data from public sources, emit
    canonical parquet + CSV, optionally INSERT OVERWRITE into Databricks Delta tables.

.DESCRIPTION
    Self-contained PowerShell 7+ refresh script. Mirrors the role of scripts/refresh.py in the
    sibling crop_varieties repository, but in PowerShell. Embedded Python handles XLSX/Parquet
    serialization (pandas + openpyxl + pyarrow).

    Sources (v1):
      Price — World Bank Pink Sheet (monthly XLSX), AfricaFertilizer.org (per-country CSV)
      Use   — FAOSTAT RFB / Fertilizers by Nutrient (ZIP), OurWorldInData (CSV), WB WDI (JSON)

    Pipeline:
      PREFLIGHT → PULL PRICE → PULL USE → NORMALIZE (Python) → PRESERVE → PUSH → LOG

.PARAMETER OutDir
    Directory for output parquet + CSV. Default: ..\data relative to this script.

.PARAMETER LogPath
    Path for refresh_log.csv. Default: <OutDir>\refresh_log.csv.

.PARAMETER SkipDatabricksPush
    Skip the Databricks INSERT OVERWRITE step. Local parquet/CSV emit only.

.PARAMETER Profile
    Databricks CLI profile name. Default: DEFAULT.

.EXAMPLE
    pwsh -File .\scripts\Refresh-FertilizerMarket.ps1
    pwsh -File .\scripts\Refresh-FertilizerMarket.ps1 -SkipDatabricksPush
    pwsh -File .\scripts\Refresh-FertilizerMarket.ps1 -Profile fairgrounds

.NOTES
    One-time setup:
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
      Unblock-File -Path <this script>
      databricks auth describe --profile DEFAULT
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\data'),
    [string]$LogPath,
    [switch]$SkipDatabricksPush,
    [string]$Profile = 'DEFAULT'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speeds up Invoke-WebRequest 50x
$startedUtc            = [datetime]::UtcNow

# ── PREFLIGHT ───────────────────────────────────────────────────────────────

Write-Host "[PREFLIGHT] pwsh version: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Requires PowerShell 7+. Current: $($PSVersionTable.PSVersion)"
}

$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not $LogPath) { $LogPath = Join-Path $OutDir 'refresh_log.csv' }

$pythonExe = (Get-Command python -ErrorAction SilentlyContinue)?.Source
if (-not $pythonExe) { throw "python not on PATH. Install Python 3.11+ with pandas + openpyxl + pyarrow." }
Write-Host "[PREFLIGHT] python: $pythonExe"

if (-not $SkipDatabricksPush) {
    $dbx = (Get-Command databricks -ErrorAction SilentlyContinue)?.Source
    if (-not $dbx) { throw "databricks CLI not on PATH. Install or use -SkipDatabricksPush." }
    Write-Host "[PREFLIGHT] databricks: $dbx (profile=$Profile)"
}

$pricesParquet = Join-Path $OutDir 'prices.parquet'
$pricesCsv     = Join-Path $OutDir 'prices.csv'
$useParquet    = Join-Path $OutDir 'use.parquet'
$useCsv        = Join-Path $OutDir 'use.csv'

$retrievedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# ── HELPERS ─────────────────────────────────────────────────────────────────

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$Max = 3,
        [int]$BackoffSec = 5,
        [string]$Label = '<unnamed>'
    )
    for ($attempt = 1; $attempt -le $Max; $attempt++) {
        try { return & $Script }
        catch {
            if ($attempt -lt $Max) {
                Write-Warning "[$Label] attempt $attempt failed: $($_.Exception.Message). retrying in ${BackoffSec}s"
                Start-Sleep -Seconds $BackoffSec
            } else { throw }
        }
    }
}

function Invoke-DatabricksSQL {
    param([Parameter(Mandatory)][string]$Statement,
          [string]$Profile = 'DEFAULT',
          [string]$WarehouseId)
    $payload = @{
        statement     = $Statement
        warehouse_id  = $WarehouseId
        wait_timeout  = '30s'
        on_wait_timeout = 'CONTINUE'
    } | ConvertTo-Json -Compress
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "dbxsql_$(Get-Random).json"
    [System.IO.File]::WriteAllText($tmp, $payload)
    try {
        Invoke-WithRetry -Label 'databricks-sql-submit' -Script {
            $raw = & databricks api post /api/2.0/sql/statements --profile $Profile --json "@$tmp" 2>&1
            $resp = $raw | Out-String | ConvertFrom-Json -ErrorAction Stop
            if (-not $resp.statement_id) { throw "no statement_id in response: $raw" }
            # poll until terminal
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
            throw "statement $sid timed out after 120s"
        }
    } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-WarehouseId {
    param([string]$Profile = 'DEFAULT')
    Invoke-WithRetry -Label 'warehouses-list' -Script {
        $raw = & databricks warehouses list --profile $Profile -o json 2>&1
        $list = $raw | Out-String | ConvertFrom-Json -ErrorAction Stop
        $running = $list | Where-Object { $_.state -in 'RUNNING','STARTING' } | Select-Object -First 1
        if (-not $running) { $running = $list | Select-Object -First 1 }
        if (-not $running) { throw "no warehouses available on profile $Profile" }
        return $running.id
    }
}

# ── PULL: PRICE SOURCES ─────────────────────────────────────────────────────

function Get-WBPinkSheet {
    param([string]$DestXlsx)
    $url = 'https://thedocs.worldbank.org/en/doc/18675f1d1639c7a34d463f59263ba0a2-0050012025/related/CMO-Historical-Data-Monthly.xlsx'
    Invoke-WithRetry -Label 'wb-pinksheet' -Script {
        Invoke-WebRequest -Uri $url -OutFile $DestXlsx -UseBasicParsing -TimeoutSec 60
    }
    Write-Host "[PRICE] WB Pink Sheet → $DestXlsx ($([math]::Round((Get-Item $DestXlsx).Length/1MB,2)) MB)"
}

# VIFAA backend uses ISO2; the rest of this script and the downstream parser use ISO3.
# Zimbabwe is not in VIFAA — callers should drop it from the ISO3 list.
$Script:VIFAA_ISO3_TO_ISO2 = @{
    'NGA'='NG'; 'ETH'='ET'; 'KEN'='KE'; 'TZA'='TZ'; 'GHA'='GH'
    'MWI'='MW'; 'MOZ'='MZ'; 'ZMB'='ZM'; 'UGA'='UG'; 'SEN'='SN'; 'RWA'='RW'
}

function ConvertTo-CanonicalProduct {
    param([string]$Name)
    $n = $Name.ToLower().Trim()
    if ($n -match 'urea') { return 'urea' }
    if ($n -match '\bdap\b|diammonium') { return 'dap' }
    if ($n -match '\bcan\b|calcium ammonium') { return 'can' }
    if ($n -match '\bmop\b|muriate|potassium chloride') { return 'mop' }
    if ($n -match '\btsp\b|triple super') { return 'tsp' }
    if ($n -match 'npk') {
        if ($n -match '(\d+)[-\s](\d+)[-\s](\d+)') { return "npk_$($Matches[1])_$($Matches[2])_$($Matches[3])" }
        return 'npk'
    }
    return (($n -replace '[^a-z0-9]+','_').Trim('_'))
}

# Pulls VIFAA retail prices via admin.africafertilizer.org/api/prices/seriesByProducts.
# Endpoint contract reverse-engineered 2026-05-22 from the SPA sourcemap at
# viz.africafertilizer.org/static/js/main.220c333c.js.map. Canonical body shape comes
# from a GET to /api/filtersDefaults/prices/seriesByProducts?countryIso=<ISO2>; we
# augment with countryIso, lang, widened dates, and an explicit currencyCode/unit pair.
# See data/_afe_discovery/{apiConnector,apiUtils,genericModule}.js + README.md.
function Get-AfricaFertilizer {
    param([string[]]$Iso3List, [string]$DestDir)
    $headers = @{
        'Origin'       = 'https://viz.africafertilizer.org'
        'Referer'      = 'https://viz.africafertilizer.org/'
        'Accept'       = 'application/json'
        'Content-Type' = 'application/json'
    }
    $base = 'https://admin.africafertilizer.org'
    $sleepSec = 2
    foreach ($iso3 in $Iso3List) {
        $iso2 = $Script:VIFAA_ISO3_TO_ISO2[$iso3]
        if (-not $iso2) {
            Write-Warning "[PRICE] AfricaFertilizer $iso3 — not in VIFAA dataset, skipping"
            continue
        }
        $dest = Join-Path $DestDir "afe_$iso3.csv"
        try {
            Invoke-WithRetry -Label "afe-$iso3" -Max 3 -BackoffSec 5 -Script {
                $defs = Invoke-RestMethod -Method GET -Headers $headers -TimeoutSec 60 `
                    -Uri "$base/api/filtersDefaults/prices/seriesByProducts?countryIso=$iso2&selectedLanguage=en"
                if (-not $defs.compoundProductsSelected -or @($defs.compoundProductsSelected).Count -eq 0) {
                    throw "no compoundProductsSelected in filter defaults for $iso2"
                }
                $bodyHash = @{}
                foreach ($p in $defs.PSObject.Properties) { $bodyHash[$p.Name] = $p.Value }
                $bodyHash['countryIso'] = $iso2
                $bodyHash['lang']       = 'en'
                $bodyHash['dates']      = @('2010-01-01','2025-12-31')
                $localCurrency = $defs.currencyCode
                $localUnit     = $defs.unit

                $bodyHash['currencyCode'] = 'USD'; $bodyHash['unit'] = 'USD_MT'
                $usdBody = $bodyHash | ConvertTo-Json -Depth 8 -Compress
                $usdResp = Invoke-RestMethod -Method POST -Headers $headers -TimeoutSec 180 `
                    -Uri "$base/api/prices/seriesByProducts" -Body $usdBody

                $bodyHash['currencyCode'] = $localCurrency; $bodyHash['unit'] = $localUnit
                $locBody = $bodyHash | ConvertTo-Json -Depth 8 -Compress
                $locResp = Invoke-RestMethod -Method POST -Headers $headers -TimeoutSec 180 `
                    -Uri "$base/api/prices/seriesByProducts" -Body $locBody

                $usdSeries = if ($usdResp -is [array]) { @($usdResp)[0].serieByMonth } else { $usdResp.serieByMonth }
                $locSeries = if ($locResp -is [array]) { @($locResp)[0].serieByMonth } else { $locResp.serieByMonth }
                if (-not $usdSeries) { throw "empty serieByMonth in USD response for $iso2" }

                $locMap = @{}
                foreach ($s in $locSeries) {
                    $key = if ($s.seriesInfo.hsCode) { "$($s.seriesInfo.hsCode)|$($s.id)" } else { $s.id }
                    $locMap[$key] = @{}
                    foreach ($d in $s.data) { if ($null -ne $d.y) { $locMap[$key][$d.x] = $d.y } }
                }

                $monthNum = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
                $rows = New-Object System.Collections.Generic.List[object]
                foreach ($s in $usdSeries) {
                    $key  = if ($s.seriesInfo.hsCode) { "$($s.seriesInfo.hsCode)|$($s.id)" } else { $s.id }
                    $prod = ConvertTo-CanonicalProduct -Name $s.id
                    foreach ($d in $s.data) {
                        if ($null -eq $d.y) { continue }
                        $parts = $d.x -split '-'
                        if ($parts.Count -ne 2 -or -not $monthNum.ContainsKey($parts[0])) { continue }
                        $locT = $null
                        if ($locMap.ContainsKey($key) -and $locMap[$key].ContainsKey($d.x)) { $locT = $locMap[$key][$d.x] }
                        $rows.Add([pscustomobject]@{
                            product           = $prod
                            product_name_raw  = $s.id
                            hs_code           = $s.seriesInfo.hsCode
                            year              = [int]$parts[1]
                            month             = $monthNum[$parts[0]]
                            price_usd_per_t   = $d.y
                            price_local_per_t = $locT
                            currency          = $localCurrency
                            market_level      = 'retail'
                        })
                    }
                }
                if ($rows.Count -eq 0) { throw "no rows extracted from $iso2 series response" }
                $rows | Export-Csv -Path $dest -NoTypeInformation -Encoding utf8
                Write-Host "[PRICE] AfricaFertilizer $iso3 ($iso2) → $dest ($($rows.Count) rows, $(($rows | Select-Object -ExpandProperty product -Unique).Count) products)"
            }
        } catch {
            $errMsg = $_.Exception.Message
            # Fallback path for countries where seriesByProducts returns empty (chad #4 — ETH 2026-05-22).
            # byProductsAndDates uses singular compoundProductSelected + townsSelected[] and returns a
            # row per (town, month, product). Slower (per-product loop) but lands data where the series
            # endpoint won't.
            if ($errMsg -match 'empty serieByMonth') {
                try {
                    Write-Host "[PRICE] AfricaFertilizer $iso3 — seriesByProducts empty, trying byProductsAndDates fallback"
                    # Filter defaults for the byProductsAndDates endpoint actually live at
                    # /filtersDefaults/prices/byProducts (per apiConnector.js line 193 — the
                    # byProducts module hosts BOTH defaultFilters AND the monthly chartData URL).
                    $bpdDefs = Invoke-RestMethod -Method GET -Headers $headers -TimeoutSec 60 `
                        -Uri "$base/api/filtersDefaults/prices/byProducts?countryIso=$iso2&selectedLanguage=en"
                    $products = @($bpdDefs.compoundProductsSelected)
                    $monthNum2 = @{ Jan=1; Feb=2; Mar=3; Apr=4; May=5; Jun=6; Jul=7; Aug=8; Sep=9; Oct=10; Nov=11; Dec=12 }
                    $fallbackRows = New-Object System.Collections.Generic.List[object]
                    foreach ($prod in $products) {
                        $bodyHash = @{}
                        foreach ($p in $bpdDefs.PSObject.Properties) { $bodyHash[$p.Name] = $p.Value }
                        $bodyHash['countryIso'] = $iso2
                        $bodyHash['lang']       = 'en'
                        $bodyHash['dates']      = @('2010-01-01','2025-12-31')
                        $bodyHash['compoundProductSelected'] = $prod
                        $bodyHash.Remove('compoundProductsSelected') | Out-Null
                        $bodyHash['currencyCode'] = 'USD'
                        $bodyHash['unit']         = 'USD_MT'
                        $body = $bodyHash | ConvertTo-Json -Depth 8 -Compress
                        try {
                            $resp = Invoke-RestMethod -Method POST -Headers $headers -TimeoutSec 120 `
                                -Uri "$base/api/prices/byProductsAndDates" -Body $body
                        } catch {
                            Write-Warning "  byProductsAndDates $iso3/$prod failed: $($_.Exception.Message)"
                            continue
                        }
                        # Response shape: array of {x: 'MMM-YYYY', y: price, ...} or
                        # nested {data:[{x,y}]} per product. Probe both.
                        $data = if ($resp -is [array] -and $resp.Count -gt 0 -and $resp[0].data) { $resp[0].data }
                                elseif ($resp.data) { $resp.data }
                                elseif ($resp -is [array]) { $resp }
                                else { @() }
                        $prodCanon = ConvertTo-CanonicalProduct -Name $prod
                        foreach ($d in $data) {
                            if ($null -eq $d.y) { continue }
                            $xs = if ($d.x) { $d.x } elseif ($d.date) { $d.date } else { $null }
                            if (-not $xs) { continue }
                            $parts = $xs -split '-'
                            if ($parts.Count -ne 2 -or -not $monthNum2.ContainsKey($parts[0])) { continue }
                            $fallbackRows.Add([pscustomobject]@{
                                product           = $prodCanon
                                product_name_raw  = $prod
                                hs_code           = $null
                                year              = [int]$parts[1]
                                month             = $monthNum2[$parts[0]]
                                price_usd_per_t   = $d.y
                                price_local_per_t = $null
                                currency          = 'USD'
                                market_level      = 'retail'
                            })
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    if ($fallbackRows.Count -gt 0) {
                        $fallbackRows | Export-Csv -Path $dest -NoTypeInformation -Encoding utf8
                        Write-Host "[PRICE] AfricaFertilizer $iso3 ($iso2) fallback → $dest ($($fallbackRows.Count) rows, $(($fallbackRows | Select-Object -ExpandProperty product -Unique).Count) products)"
                    } else {
                        Write-Warning "[PRICE] AfricaFertilizer $iso3 fallback produced 0 rows — both endpoints empty"
                    }
                } catch {
                    Write-Warning "[PRICE] AfricaFertilizer $iso3 fallback failed: $($_.Exception.Message) — skipping"
                }
            } else {
                Write-Warning "[PRICE] AfricaFertilizer $iso3 failed: $errMsg — skipping"
            }
        }
        Start-Sleep -Seconds $sleepSec
    }
}

# ── PULL: USE SOURCES ───────────────────────────────────────────────────────

function Get-FAOSTATFertNutrient {
    param([string]$DestZip)
    # Normalized variant: long-format CSV with a Year column (vs the wide format which has Y1961…Y2023 cols).
    # Only Nitrogen (Item Code 3102) is exposed in this bulk; P2O5 + K2O come from the Product bulk.
    $url = 'https://fenixservices.fao.org/faostat/static/bulkdownloads/Inputs_FertilizersNutrient_E_All_Data_(Normalized).zip'
    Invoke-WithRetry -Label 'faostat-zip' -Script {
        Invoke-WebRequest -Uri $url -OutFile $DestZip -UseBasicParsing -TimeoutSec 180
    }
    Write-Host "[USE] FAOSTAT Nutrient ZIP → $DestZip ($([math]::Round((Get-Item $DestZip).Length/1MB,2)) MB)"
}

function Get-FAOSTATFertProduct {
    param([string]$DestZip)
    # FertilizersProduct bulk — per-product Agricultural Use in tonnes. Used to derive P2O5 + K2O
    # tonnes via known nutrient content (urea=46%N, DAP=18N/46P2O5, MOP=60K2O, etc.). The RFN
    # bulk only carries Nitrogen so P+K must come from here. Item codes 4001-4030.
    $url = 'https://fenixservices.fao.org/faostat/static/bulkdownloads/Inputs_FertilizersProduct_E_All_Data_(Normalized).zip'
    Invoke-WithRetry -Label 'faostat-product-zip' -Script {
        Invoke-WebRequest -Uri $url -OutFile $DestZip -UseBasicParsing -TimeoutSec 180
    }
    Write-Host "[USE] FAOSTAT Product ZIP → $DestZip ($([math]::Round((Get-Item $DestZip).Length/1MB,2)) MB)"
}

function Get-OWIDFertUse {
    param([string]$DestCsv)
    $url = 'https://ourworldindata.org/grapher/fertilizer-use-in-kg-per-hectare-of-arable-land.csv'
    Invoke-WithRetry -Label 'owid-fert' -Script {
        Invoke-WebRequest -Uri $url -OutFile $DestCsv -UseBasicParsing -TimeoutSec 60
    }
    Write-Host "[USE] OWID → $DestCsv"
}

function Get-WBWDIFertUse {
    param([string]$DestJson)
    # AG.CON.FERT.ZS = Fertilizer consumption (kg/ha of arable land)
    $url = 'https://api.worldbank.org/v2/country/all/indicator/AG.CON.FERT.ZS?format=json&per_page=20000'
    Invoke-WithRetry -Label 'wb-wdi' -Script {
        Invoke-WebRequest -Uri $url -OutFile $DestJson -UseBasicParsing -TimeoutSec 90
    }
    Write-Host "[USE] WB WDI → $DestJson"
}

# ── EXECUTE PULLS ───────────────────────────────────────────────────────────

$staging = Join-Path ([System.IO.Path]::GetTempPath()) "fertilizer_market_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$afeDir = Join-Path $staging 'afe'; New-Item -ItemType Directory -Path $afeDir -Force | Out-Null
Write-Host "[STAGING] $staging"

$results = @{
    wb_pinksheet      = $null
    africafertilizer  = $null
    faostat           = $null
    faostat_product   = $null
    owid              = $null
    wb_wdi            = $null
}

try { Get-WBPinkSheet -DestXlsx (Join-Path $staging 'pinksheet.xlsx');     $results.wb_pinksheet = 'ok' }
catch { Write-Warning "[PRICE] Pink Sheet failed: $($_.Exception.Message)"; $results.wb_pinksheet = "fail: $($_.Exception.Message)" }

try {
    Get-AfricaFertilizer -Iso3List @('NGA','ETH','KEN','TZA','GHA','MWI','MOZ','ZMB','UGA','SEN','RWA') -DestDir $afeDir
    $results.africafertilizer = 'ok'
} catch { Write-Warning "[PRICE] AFE failed: $($_.Exception.Message)"; $results.africafertilizer = "fail: $($_.Exception.Message)" }

try { Get-FAOSTATFertNutrient -DestZip (Join-Path $staging 'faostat.zip'); $results.faostat = 'ok' }
catch { Write-Warning "[USE] FAOSTAT failed: $($_.Exception.Message)"; $results.faostat = "fail: $($_.Exception.Message)" }

try { Get-FAOSTATFertProduct -DestZip (Join-Path $staging 'faostat_product.zip'); $results.faostat_product = 'ok' }
catch { Write-Warning "[USE] FAOSTAT Product failed: $($_.Exception.Message)"; $results.faostat_product = "fail: $($_.Exception.Message)" }

try { Get-OWIDFertUse -DestCsv (Join-Path $staging 'owid.csv');           $results.owid = 'ok' }
catch { Write-Warning "[USE] OWID failed: $($_.Exception.Message)"; $results.owid = "fail: $($_.Exception.Message)" }

try { Get-WBWDIFertUse -DestJson (Join-Path $staging 'wb_wdi.json');      $results.wb_wdi = 'ok' }
catch { Write-Warning "[USE] WB WDI failed: $($_.Exception.Message)"; $results.wb_wdi = "fail: $($_.Exception.Message)" }

# ── NORMALIZE (embedded Python) ─────────────────────────────────────────────

$pyScript = @'
"""Normalize staged sources -> prices.parquet + use.parquet.
Args:
  --staging <dir>  : where pulled files live (afe/, pinksheet.xlsx, faostat.zip, owid.csv, wb_wdi.json)
  --out-prices <path> : prices.parquet output
  --out-use    <path> : use.parquet output
  --retrieved-at <iso8601> : timestamp string to stamp on all rows
  --preserve-from <dir> : optional. If sources failed, keep rows from previous parquet at this dir.
  --results-json <json string> : per-source ok/fail
"""
from __future__ import annotations
import argparse, csv, io, json, os, re, sys, zipfile
from pathlib import Path
import pandas as pd

ap = argparse.ArgumentParser()
ap.add_argument('--staging', required=True)
ap.add_argument('--out-prices', required=True)
ap.add_argument('--out-use',    required=True)
ap.add_argument('--retrieved-at', required=True)
ap.add_argument('--preserve-from', default=None)
ap.add_argument('--results-json', required=True)
args = ap.parse_args()

staging = Path(args.staging)
retrieved_at = args.retrieved_at
results = json.loads(args.results_json)

PRICE_COLS = ['source','source_record_id','country_iso3','country_name','product','product_grade',
              'market_level','year','month','price_usd_per_t','price_local_per_t','currency',
              'source_url','retrieved_at','review_flags']
USE_COLS   = ['source','source_record_id','country_iso3','country_name','year','nutrient',
              'total_tonnes','kg_per_ha_arable','arable_land_ha','source_url','retrieved_at','review_flags']

def empty(cols): return pd.DataFrame({c: pd.Series(dtype='object') for c in cols})
prices = empty(PRICE_COLS); use = empty(USE_COLS)

# ── WB Pink Sheet (monthly XLSX) ────────────────────────────────────────────
if results.get('wb_pinksheet') == 'ok':
    src_url = 'https://thedocs.worldbank.org/.../CMO-Historical-Data-Monthly.xlsx'
    xlsx = staging / 'pinksheet.xlsx'
    try:
        # Sheet name drifts ('Monthly Prices' vs 'Monthly Indices'); regex-match it.
        xls = pd.ExcelFile(xlsx, engine='openpyxl')
        sheet = next((s for s in xls.sheet_names if re.match(r'^Monthly Prices', s, re.I)), None)
        if not sheet: sheet = next((s for s in xls.sheet_names if re.match(r'^Monthly', s, re.I)), None)
        if not sheet: raise RuntimeError(f'no Monthly sheet in {xls.sheet_names}')
        # Header at row 6 (index 4) per WB convention; date in col A as YYYYMmm or YYYY-MM
        df = pd.read_excel(xlsx, sheet_name=sheet, engine='openpyxl', header=4)
        df = df.rename(columns={df.columns[0]: 'date_raw'})
        # Parse YYYYMmm into year + month
        def parse_d(s):
            m = re.match(r'^(\d{4})M(\d{1,2})$', str(s).strip())
            if m: return int(m.group(1)), int(m.group(2))
            m = re.match(r'^(\d{4})-(\d{1,2})', str(s).strip())
            if m: return int(m.group(1)), int(m.group(2))
            return None, None
        df[['year','month']] = df['date_raw'].apply(lambda s: pd.Series(parse_d(s)))
        df = df.dropna(subset=['year','month'])
        # Known fertilizer-relevant columns; matches Pink Sheet field naming
        wanted = {
            'Urea, (Ukraine), f.o.b.': ('urea','global_fob','prilled'),
            'Urea': ('urea','global_fob','prilled'),
            'DAP': ('dap','global_fob','granular'),
            'Phosphate rock': ('phosphate_rock','global_fob','bulk'),
            'TSP': ('tsp','global_fob','granular'),
            'Potassium chloride': ('mop','global_fob','granular'),
            'Potassium chloride (Muriate of Potash)': ('mop','global_fob','granular'),
        }
        ps_rows = []
        for col, (prod, level, grade) in wanted.items():
            if col not in df.columns:
                cand = [c for c in df.columns if isinstance(c,str) and col.lower().split(',')[0].strip() in c.lower()]
                if not cand: continue
                col = cand[0]
            sub = df[['year','month',col]].copy()
            # Pink Sheet uses literal '...' for missing values. Coerce to NaN then dropna.
            sub[col] = pd.to_numeric(sub[col], errors='coerce')
            sub = sub.dropna()
            for rec in sub.itertuples(index=False):
                y, m, v = rec
                ps_rows.append({
                    'source':'wb_pinksheet',
                    'source_record_id': f'wb_pinksheet|{prod}|GLB|{int(y)}-{int(m):02d}',
                    'country_iso3': None, 'country_name': None,
                    'product': prod, 'product_grade': grade, 'market_level': level,
                    'year': int(y), 'month': int(m),
                    'price_usd_per_t': float(v),
                    'price_local_per_t': None, 'currency': 'USD',
                    'source_url': src_url, 'retrieved_at': retrieved_at,
                    'review_flags': '',
                })
        if ps_rows:
            prices = pd.concat([prices, pd.DataFrame(ps_rows, columns=PRICE_COLS)], ignore_index=True)
        print(f'wb_pinksheet rows: {len(ps_rows)}', file=sys.stderr)
    except Exception as e:
        print(f'wb_pinksheet parse failed: {e}', file=sys.stderr)

# ── AfricaFertilizer per-country CSVs (vectorized) ──────────────────────────
if results.get('africafertilizer') == 'ok':
    src_url = 'https://africafertilizer.org/api/prices/csv'
    afe_dir = staging / 'afe'
    afe_rows = []
    if afe_dir.exists():
        for csv_path in afe_dir.glob('afe_*.csv'):
            iso = csv_path.stem.split('_',1)[1]
            try:
                df = pd.read_csv(csv_path)
                cols_lower = {c.lower(): c for c in df.columns}
                def pick(*names):
                    for n in names:
                        if n in cols_lower: return cols_lower[n]
                    return None
                col_prod  = pick('product','fertilizer','commodity')
                col_year  = pick('year')
                col_month = pick('month')
                col_date  = pick('date','period')
                col_usd   = pick('price_usd','usd','price_usd_per_t','price (usd/mt)')
                col_loc   = pick('price_local','local','price_local_per_t')
                col_curr  = pick('currency','ccy')
                col_lvl   = pick('market_level','level')
                for _, r in df.iterrows():
                    y = None; m = None
                    if col_year and col_month:
                        try: y, m = int(r[col_year]), int(r[col_month])
                        except: y, m = None, None
                    elif col_date:
                        try:
                            dt = pd.to_datetime(r[col_date], errors='coerce')
                            if pd.notna(dt): y, m = dt.year, dt.month
                        except: pass
                    if y is None or m is None: continue
                    prod_raw = str(r[col_prod]).strip().lower() if col_prod else 'urea'
                    prod = {'urea':'urea','dap':'dap','npk':'npk_15_15_15','potash':'mop','mop':'mop','tsp':'tsp'}.get(
                        prod_raw, re.sub(r'[^a-z0-9_]+','_', prod_raw))
                    afe_rows.append({
                        'source':'africafertilizer',
                        'source_record_id': f'afe|{prod}|{iso}|{y}-{m:02d}',
                        'country_iso3': iso, 'country_name': None,
                        'product': prod, 'product_grade': None,
                        'market_level': str(r[col_lvl]).lower() if col_lvl else 'retail',
                        'year': y, 'month': m,
                        'price_usd_per_t': float(r[col_usd]) if col_usd and pd.notna(r[col_usd]) else None,
                        'price_local_per_t': float(r[col_loc]) if col_loc and pd.notna(r[col_loc]) else None,
                        'currency': str(r[col_curr]) if col_curr and pd.notna(r[col_curr]) else None,
                        'source_url': src_url, 'retrieved_at': retrieved_at, 'review_flags': '',
                    })
            except Exception as e:
                print(f'afe {iso} parse failed: {e}', file=sys.stderr)
    if afe_rows:
        prices = pd.concat([prices, pd.DataFrame(afe_rows, columns=PRICE_COLS)], ignore_index=True)
    print(f'africafertilizer rows: {len(afe_rows)}', file=sys.stderr)

# ── FAOSTAT RFN (Fertilizers by Nutrient, Normalized — long format) ─────────
# Real schema (verified 2026-05-22):
#   columns: Area Code, Area Code (M49), Area, Item Code, Item, Element Code,
#            Element, Year Code, Year, Unit, Value, Flag, Note
#   ItemCodes: 3102 = Nutrient nitrogen N (total) — ONLY N is in this bulk
#   ElementCodes: 5157 Agricultural Use (tonnes), 5159 Use per area of cropland
#                 (kg/ha), plus 5510/5610/5910 production/import/export
#   Area Code (M49) is a quoted-apostrophe string like "'004" — strip the prefix
#     and look up via pycountry.countries.get(numeric=<m49>).alpha_3
if results.get('faostat') == 'ok':
    src_url = 'https://fenixservices.fao.org/faostat/static/bulkdownloads/Inputs_FertilizersNutrient_E_All_Data_(Normalized).zip'
    z = staging / 'faostat.zip'
    try:
        try:
            import pycountry
        except ImportError:
            raise RuntimeError('pycountry not installed — pip install pycountry')
        with zipfile.ZipFile(z) as zf:
            csv_name = next((n for n in zf.namelist() if n.lower().endswith('.csv') and 'all_data' in n.lower()), None)
            if not csv_name:
                csv_name = next(n for n in zf.namelist() if n.lower().endswith('.csv'))
            with zf.open(csv_name) as fh:
                raw = fh.read()
        try: txt = raw.decode('utf-8-sig')
        except UnicodeDecodeError: txt = raw.decode('latin-1')
        df = pd.read_csv(io.StringIO(txt), low_memory=False)
        # Filter to nutrient items and use-related elements
        item_map = {3102: 'N', 3103: 'P2O5', 3104: 'K2O'}
        element_to_field = {5157: 'total_tonnes', 5159: 'kg_per_ha_arable'}
        df = df[df['Item Code'].isin(item_map.keys()) & df['Element Code'].isin(element_to_field.keys())]
        # Build M49 → ISO3 lookup once, cached
        m49_cache = {}
        def m49_to_iso3(m49_str):
            key = str(m49_str).lstrip("'").strip().zfill(3)
            if key in m49_cache: return m49_cache[key]
            try:
                obj = pycountry.countries.get(numeric=key)
                iso = obj.alpha_3 if obj else None
            except Exception:
                iso = None
            m49_cache[key] = iso
            return iso
        # Vectorized: pre-compute all derived columns then build the rows in one DataFrame concat.
        # The .loc[len(df)] = row append pattern is O(n^2) and was the wallclock killer
        # on the first attempt (>15 min on ~50k FAOSTAT rows).
        df = df.dropna(subset=['Value','Year','Area Code (M49)','Item Code','Element Code'])
        df['iso3'] = df['Area Code (M49)'].map(m49_to_iso3)
        df = df.dropna(subset=['iso3'])
        df['year_i']    = df['Year'].astype(int)
        df['nutrient']  = df['Item Code'].astype(int).map(item_map)
        df['field']     = df['Element Code'].astype(int).map(element_to_field)
        df['val_f']     = df['Value'].astype(float)
        df['elt_code']  = df['Element Code'].astype(int)
        # Build one row dict per record, route value into the right field
        new_rows = []
        for rec in df[['iso3','Area','year_i','nutrient','field','val_f','elt_code']].itertuples(index=False):
            row = {
                'source':'faostat',
                'source_record_id': f'faostat|{rec.iso3}|{rec.nutrient}|{rec.year_i}|{rec.elt_code}',
                'country_iso3': rec.iso3,
                'country_name': rec.Area,
                'year': rec.year_i,
                'nutrient': rec.nutrient,
                'total_tonnes': None,
                'kg_per_ha_arable': None,
                'arable_land_ha': None,
                'source_url': src_url,
                'retrieved_at': retrieved_at,
                'review_flags': '',
            }
            row[rec.field] = rec.val_f
            new_rows.append(row)
        if new_rows:
            use = pd.concat([use, pd.DataFrame(new_rows, columns=USE_COLS)], ignore_index=True)
        print(f'faostat rows: {len(new_rows)}', file=sys.stderr)
    except Exception as e:
        print(f'faostat parse failed: {e}', file=sys.stderr)

# ── FAOSTAT FertilizersProduct → derive P2O5 + K2O ──────────────────────────
# The Nutrient (RFN) bulk above only carries Item Code 3102 (N). FAOSTAT splits
# P2O5 and K2O out of the public bulk download. We derive them from the Product
# (RFB) bulk: per-product Agricultural Use (tonnes) × known nutrient content.
# Only stable single-nutrient + canonical compound products are derived; variable
# composition products (NPK compounds, "Other", "n.e.c.") are skipped.
# Rows are tagged source='faostat_product' and nutrient ∈ {P2O5, K2O} (N is
# omitted — already covered by the direct RFN block above with higher fidelity).
if results.get('faostat_product') == 'ok':
    src_url = 'https://fenixservices.fao.org/faostat/static/bulkdownloads/Inputs_FertilizersProduct_E_All_Data_(Normalized).zip'
    z = staging / 'faostat_product.zip'
    try:
        try:
            import pycountry
        except ImportError:
            raise RuntimeError('pycountry not installed — pip install pycountry')
        with zipfile.ZipFile(z) as zf:
            csv_name = next((n for n in zf.namelist() if n.lower().endswith('.csv') and 'all_data' in n.lower()), None)
            if not csv_name:
                csv_name = next(n for n in zf.namelist() if n.lower().endswith('.csv'))
            with zf.open(csv_name) as fh:
                raw = fh.read()
        try: txt = raw.decode('utf-8-sig')
        except UnicodeDecodeError: txt = raw.decode('latin-1')
        df = pd.read_csv(io.StringIO(txt), low_memory=False)
        # Stable-composition products → (P2O5_pct, K2O_pct). N omitted — RFN has it
        # directly with higher accuracy. Variable products (4008/4014/4018/4021/4024/4026/4030)
        # skipped.
        product_pk = {
            4001: ( 0.0,  0.0),  # Urea — 46N, no P/K (skip)
            4002: ( 0.0,  0.0),  # Ammonium sulphate — 21N (skip)
            4003: ( 0.0,  0.0),  # Ammonium nitrate — 33N (skip)
            4004: ( 0.0,  0.0),  # CAN — 27N (skip)
            4005: ( 0.0,  0.0),  # Sodium nitrate — 16N (skip)
            4006: ( 0.0,  0.0),  # UAN — varies (skip)
            4007: ( 0.0,  0.0),  # Anhydrous ammonia — 82N (skip)
            4011: (33.0,  0.0),  # Phosphate rock — ~33% P2O5
            4012: (46.0,  0.0),  # TSP / SSP above 35% — 46% P2O5
            4013: (16.0,  0.0),  # Other SSP — 16% P2O5
            4016: ( 0.0, 60.0),  # MOP / KCl — 60% K2O
            4017: ( 0.0, 50.0),  # SOP — 50% K2O
            4022: (46.0,  0.0),  # DAP — 18N + 46% P2O5
            4023: (52.0,  0.0),  # MAP — 11N + 52% P2O5
            4025: ( 0.0, 44.0),  # KNO3 — 13N + 44% K2O
            4027: (30.0, 30.0),  # PK compounds — 30/30
        }
        # Keep only products with non-zero P or K contribution
        useful_items = {k:v for k,v in product_pk.items() if v[0] > 0 or v[1] > 0}
        df = df[df['Item Code'].isin(useful_items.keys()) & (df['Element Code'].astype(int) == 5157)]
        m49_cache = {}
        def m49_to_iso3_p(m49_str):
            key = str(m49_str).lstrip("'").strip().zfill(3)
            if key in m49_cache: return m49_cache[key]
            try: obj = pycountry.countries.get(numeric=key); iso = obj.alpha_3 if obj else None
            except Exception: iso = None
            m49_cache[key] = iso
            return iso
        df = df.dropna(subset=['Value','Year','Area Code (M49)','Item Code'])
        df['iso3'] = df['Area Code (M49)'].map(m49_to_iso3_p)
        df = df.dropna(subset=['iso3'])
        df['year_i']    = df['Year'].astype(int)
        df['item_code'] = df['Item Code'].astype(int)
        df['tonnes']    = df['Value'].astype(float)
        # Aggregate by (iso3, area, year, item) — should already be unique but safe
        agg = df.groupby(['iso3','Area','year_i','item_code'], as_index=False)['tonnes'].sum()
        prod_rows = []
        for rec in agg.itertuples(index=False):
            p2o5_pct, k2o_pct = useful_items[rec.item_code]
            if p2o5_pct > 0:
                prod_rows.append({
                    'source':'faostat_product',
                    'source_record_id': f'faostat_product|{rec.iso3}|P2O5|{rec.year_i}|{rec.item_code}',
                    'country_iso3': rec.iso3, 'country_name': rec.Area,
                    'year': rec.year_i, 'nutrient': 'P2O5',
                    'total_tonnes': rec.tonnes * (p2o5_pct / 100.0),
                    'kg_per_ha_arable': None, 'arable_land_ha': None,
                    'source_url': src_url, 'retrieved_at': retrieved_at,
                    'review_flags': f'derived_from_item_{rec.item_code}',
                })
            if k2o_pct > 0:
                prod_rows.append({
                    'source':'faostat_product',
                    'source_record_id': f'faostat_product|{rec.iso3}|K2O|{rec.year_i}|{rec.item_code}',
                    'country_iso3': rec.iso3, 'country_name': rec.Area,
                    'year': rec.year_i, 'nutrient': 'K2O',
                    'total_tonnes': rec.tonnes * (k2o_pct / 100.0),
                    'kg_per_ha_arable': None, 'arable_land_ha': None,
                    'source_url': src_url, 'retrieved_at': retrieved_at,
                    'review_flags': f'derived_from_item_{rec.item_code}',
                })
        # Roll up multiple products per (country, year, nutrient) into a single row
        if prod_rows:
            pdf = pd.DataFrame(prod_rows, columns=USE_COLS)
            rollup = (pdf.groupby(['country_iso3','country_name','year','nutrient'], as_index=False)
                         .agg({'total_tonnes':'sum',
                               'review_flags': lambda s: 'derived_from_items:' + ','.join(sorted(set(
                                   ','.join(s).replace('derived_from_item_','').split(','))))}))
            rollup['source']           = 'faostat_product'
            rollup['source_record_id'] = (rollup['source'] + '|' + rollup['country_iso3'] + '|' +
                                          rollup['nutrient'] + '|' + rollup['year'].astype(str))
            rollup['kg_per_ha_arable'] = None
            rollup['arable_land_ha']   = None
            rollup['source_url']       = src_url
            rollup['retrieved_at']     = retrieved_at
            rollup = rollup[USE_COLS]
            use = pd.concat([use, rollup], ignore_index=True)
            print(f'faostat_product rows: {len(rollup)} (from {len(prod_rows)} product-nutrient pairs)', file=sys.stderr)
        else:
            print('faostat_product rows: 0', file=sys.stderr)
    except Exception as e:
        print(f'faostat_product parse failed: {e}', file=sys.stderr)

# ── OWID ────────────────────────────────────────────────────────────────────
# Vectorized — same pattern as the FAOSTAT block. The original .loc[len(use)] = row
# pattern was O(n^2) and the cause of the 13+ min wallclock seen 2026-05-22.
if results.get('owid') == 'ok':
    src_url = 'https://ourworldindata.org/grapher/fertilizer-use-in-kg-per-hectare-of-arable-land.csv'
    try:
        df = pd.read_csv(staging / 'owid.csv')
        # OWID schema: Entity, Code, Year, <value column>
        val_col = next((c for c in df.columns if c not in ('Entity','Code','Year') and df[c].dtype.kind in 'fi'), None)
        if val_col:
            sub = df.dropna(subset=['Code','Year', val_col]).copy()
            sub['year_i'] = sub['Year'].astype(int)
            sub['val_f']  = sub[val_col].astype(float)
            sub['Code']   = sub['Code'].astype(str)
            owid_rows = []
            for rec in sub[['Code','Entity','year_i','val_f']].itertuples(index=False):
                owid_rows.append({
                    'source':'owid',
                    'source_record_id': f'owid|{rec.Code}|total|{rec.year_i}',
                    'country_iso3': rec.Code, 'country_name': rec.Entity,
                    'year': rec.year_i, 'nutrient': 'total',
                    'total_tonnes': None, 'kg_per_ha_arable': rec.val_f,
                    'arable_land_ha': None,
                    'source_url': src_url, 'retrieved_at': retrieved_at, 'review_flags': '',
                })
            if owid_rows:
                use = pd.concat([use, pd.DataFrame(owid_rows, columns=USE_COLS)], ignore_index=True)
            print(f'owid rows: {len(owid_rows)}', file=sys.stderr)
    except Exception as e:
        print(f'owid parse failed: {e}', file=sys.stderr)

# ── WB WDI ──────────────────────────────────────────────────────────────────
# Vectorized — same pattern.
if results.get('wb_wdi') == 'ok':
    src_url = 'https://api.worldbank.org/v2/country/all/indicator/AG.CON.FERT.ZS'
    try:
        with open(staging / 'wb_wdi.json','r',encoding='utf-8') as fh:
            blob = json.load(fh)
        rows = blob[1] if isinstance(blob, list) and len(blob) > 1 else []
        wdi_rows = []
        for r in rows:
            iso3 = (r.get('countryiso3code') or '').strip()
            if not iso3 or not re.match(r'^[A-Z]{3}$', iso3): continue
            yr = r.get('date'); val = r.get('value')
            if val is None: continue
            try: year_i = int(yr)
            except: continue
            wdi_rows.append({
                'source':'wb_wdi',
                'source_record_id': f'wb_wdi|{iso3}|total|{year_i}',
                'country_iso3': iso3, 'country_name': (r.get('country') or {}).get('value'),
                'year': year_i, 'nutrient': 'total',
                'total_tonnes': None, 'kg_per_ha_arable': float(val),
                'arable_land_ha': None,
                'source_url': src_url, 'retrieved_at': retrieved_at, 'review_flags': '',
            })
        if wdi_rows:
            use = pd.concat([use, pd.DataFrame(wdi_rows, columns=USE_COLS)], ignore_index=True)
        print(f'wb_wdi rows: {len(wdi_rows)}', file=sys.stderr)
    except Exception as e:
        print(f'wb_wdi parse failed: {e}', file=sys.stderr)

# ── PRESERVE prior rows for any source that failed ──────────────────────────
def preserve(df, prev_path, src_status, cols):
    if not prev_path or not Path(prev_path).exists(): return df
    try: prev = pd.read_parquet(prev_path)
    except Exception: return df
    failed_sources = [k for k, v in src_status.items() if v != 'ok']
    if not failed_sources: return df
    keep = prev[prev['source'].isin(failed_sources)]
    if keep.empty: return df
    print(f'preserved {len(keep)} rows for failed sources {failed_sources} from {prev_path}', file=sys.stderr)
    return pd.concat([df, keep], ignore_index=True)[cols]

price_results = {k: results.get(k) for k in ('wb_pinksheet','africafertilizer')}
use_results   = {k: results.get(k) for k in ('faostat','owid','wb_wdi')}
if args.preserve_from:
    prev_dir = Path(args.preserve_from)
    prices = preserve(prices, prev_dir / 'prices.parquet', price_results, PRICE_COLS)
    use    = preserve(use,    prev_dir / 'use.parquet',    use_results,   USE_COLS)

# ── Type discipline ─────────────────────────────────────────────────────────
for col in ('year','month'):
    if col in prices.columns:
        prices[col] = pd.to_numeric(prices[col], errors='coerce').astype('Int32')
prices['price_usd_per_t']   = pd.to_numeric(prices['price_usd_per_t'], errors='coerce')
prices['price_local_per_t'] = pd.to_numeric(prices['price_local_per_t'], errors='coerce')

use['year'] = pd.to_numeric(use['year'], errors='coerce').astype('Int32')
for c in ('total_tonnes','kg_per_ha_arable','arable_land_ha'):
    use[c] = pd.to_numeric(use[c], errors='coerce')

# ── Emit ────────────────────────────────────────────────────────────────────
Path(args.out_prices).parent.mkdir(parents=True, exist_ok=True)
prices[PRICE_COLS].to_parquet(args.out_prices, compression='snappy', index=False)
prices[PRICE_COLS].to_csv(Path(args.out_prices).with_suffix('.csv'), index=False, encoding='utf-8')
use[USE_COLS].to_parquet(args.out_use, compression='snappy', index=False)
use[USE_COLS].to_csv(Path(args.out_use).with_suffix('.csv'), index=False, encoding='utf-8')

print(json.dumps({
    'prices_rows': int(len(prices)),
    'use_rows':    int(len(use)),
    'prices_by_source': prices['source'].value_counts().to_dict(),
    'use_by_source':    use['source'].value_counts().to_dict(),
}))
'@

$tmpPy = Join-Path ([System.IO.Path]::GetTempPath()) "fertilizer_normalize_$(Get-Random).py"
[System.IO.File]::WriteAllText($tmpPy, $pyScript)

# Build args (preserve previous parquet to handle partial-source failures)
$preserveArg = if (Test-Path $pricesParquet) { @('--preserve-from', $OutDir) } else { @() }
$resultsJson = ($results | ConvertTo-Json -Compress)

try {
    Write-Host "[NORMALIZE] invoking embedded Python ($tmpPy)"
    $stdout = & $pythonExe $tmpPy `
        --staging       $staging `
        --out-prices    $pricesParquet `
        --out-use       $useParquet `
        --retrieved-at  $retrievedAt `
        --results-json  $resultsJson `
        @preserveArg
    if ($LASTEXITCODE -ne 0) { throw "Python normalize failed with exit $LASTEXITCODE" }
    $summary = ($stdout | Select-Object -Last 1) | ConvertFrom-Json
    Write-Host "[NORMALIZE] prices_rows=$($summary.prices_rows) use_rows=$($summary.use_rows)"
} finally {
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue
}

# ── PUSH TO DATABRICKS ──────────────────────────────────────────────────────

if (-not $SkipDatabricksPush) {
    $stagingVolume = '/Volumes/ggo_agdev/bioinputs/_staging'
    Write-Host "[PUSH] resolving warehouse on profile $Profile"
    $warehouseId = Get-WarehouseId -Profile $Profile

    Write-Host "[PUSH] ensuring volume staging path exists"
    & databricks fs mkdir "dbfs:$stagingVolume" --profile $Profile 2>&1 | Out-Null

    Write-Host "[PUSH] uploading prices.parquet"
    Invoke-WithRetry -Label 'fs-cp-prices' -Script {
        & databricks fs cp $pricesParquet "dbfs:$stagingVolume/prices.parquet" --overwrite --profile $Profile
        if ($LASTEXITCODE -ne 0) { throw "databricks fs cp prices failed" }
    }
    Write-Host "[PUSH] uploading use.parquet"
    Invoke-WithRetry -Label 'fs-cp-use' -Script {
        & databricks fs cp $useParquet "dbfs:$stagingVolume/use.parquet" --overwrite --profile $Profile
        if ($LASTEXITCODE -ne 0) { throw "databricks fs cp use failed" }
    }

    $insertPrices = @"
INSERT OVERWRITE ggo_agdev.bioinputs.fertilizer_price
SELECT source, source_record_id, country_iso3, country_name, product, product_grade,
       market_level, CAST(year AS INT) AS year, CAST(month AS INT) AS month,
       price_usd_per_t, price_local_per_t, currency, source_url, retrieved_at, review_flags
FROM read_files('$stagingVolume/prices.parquet', format => 'parquet')
"@
    $insertUse = @"
INSERT OVERWRITE ggo_agdev.bioinputs.fertilizer_use
SELECT source, source_record_id, country_iso3, country_name, CAST(year AS INT) AS year,
       nutrient, total_tonnes, kg_per_ha_arable, arable_land_ha,
       source_url, retrieved_at, review_flags
FROM read_files('$stagingVolume/use.parquet', format => 'parquet')
"@

    Write-Host "[PUSH] INSERT OVERWRITE fertilizer_price"
    Invoke-DatabricksSQL -Statement $insertPrices -Profile $Profile -WarehouseId $warehouseId | Out-Null
    Write-Host "[PUSH] INSERT OVERWRITE fertilizer_use"
    Invoke-DatabricksSQL -Statement $insertUse -Profile $Profile -WarehouseId $warehouseId | Out-Null
}

# ── LOG ─────────────────────────────────────────────────────────────────────

$wallclockSec = [int]([datetime]::UtcNow - $startedUtc).TotalSeconds
$logRow = [pscustomobject]@{
    timestamp_utc     = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    wallclock_seconds = $wallclockSec
    prices_rows       = $summary.prices_rows
    use_rows          = $summary.use_rows
    sources_status    = ($results | ConvertTo-Json -Compress)
    databricks_pushed = (-not $SkipDatabricksPush.IsPresent)
    exit_status       = 'ok'
}
if (Test-Path $LogPath) {
    $logRow | Export-Csv -Path $LogPath -NoTypeInformation -Append -Encoding utf8
} else {
    $logRow | Export-Csv -Path $LogPath -NoTypeInformation -Encoding utf8
}

Write-Host "[DONE] wallclock=${wallclockSec}s  prices=$($summary.prices_rows)  use=$($summary.use_rows)  log=$LogPath"

# Cleanup staging
Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
