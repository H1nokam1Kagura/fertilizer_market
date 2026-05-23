<#
.SYNOPSIS
    Refresh-IndiaNBS.ps1 — Scrape India PIB press releases for Nutrient-Based Subsidy
    (NBS) rate-change events. Emit canonical CSV/Parquet that conforms to the
    fertilizer_price schema (market_level='subsidy_inr_per_kg').

.DESCRIPTION
    Self-contained PowerShell 7+ scraper. The Cabinet Committee on Economic Affairs
    (CCEA) approves NBS rates twice yearly (kharif + rabi seasons). Each approval is
    announced via a Press Information Bureau (PIB) press release with a unique PRID.

    Pipeline:
      PREFLIGHT → READ SEED → FETCH HTML → PARSE (embedded Python + BeautifulSoup)
        → EMIT CANONICAL → LOG

    The seed CSV (data/canonical/nbs_pib_seeds.csv) is the authoritative input list.
    The script does NOT auto-discover PRIDs from PIB search — that's a v2 task and
    PIB's search backend (PressReleseSearchUni.aspx) uses Web Forms postback that's
    hostile to scrape reliably. Curate the seed list manually.

    Output schema matches gates_open_data.open_data.fertilizer_price:
      source           = 'india_pib_nbs'
      source_record_id = 'pib_nbs|<PRID>|<nutrient>|<YYYY-MM>'
      country_iso3     = 'IND'
      product          = 'N' | 'P' | 'K' | 'S'   (the nutrient — NOT a product)
      market_level     = 'subsidy_inr_per_kg'
      price_local_per_t = rate_inr_per_kg * 1000
      currency         = 'INR'
      review_flags     = 'parsed_from_html' | 'manual_extract_required'

.PARAMETER OutDir
    Directory for output. Default: ..\data relative to this script.

.PARAMETER SeedCsv
    Path to PRID seed file. Default: <OutDir>\canonical\nbs_pib_seeds.csv.

.PARAMETER StagingDir
    Directory for raw HTML caches. Default: <OutDir>\india_pib_nbs.

.PARAMETER ForceRefetch
    Re-fetch HTML even if a cached copy exists for a given PRID.

.EXAMPLE
    pwsh -File .\scripts\Refresh-IndiaNBS.ps1
    pwsh -File .\scripts\Refresh-IndiaNBS.ps1 -ForceRefetch

.NOTES
    One-time setup:
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
      Unblock-File -Path <this script>
      pip install pandas beautifulsoup4 lxml pyarrow

    Databricks push intentionally NOT included in v1 — this dataset needs review
    before merging into the canonical fertilizer_price table. Inspect
    data/india_pib_nbs_rates.csv first.
#>
[CmdletBinding()]
param(
    [string]$OutDir       = (Join-Path $PSScriptRoot '..\data'),
    [string]$SeedCsv,
    [string]$StagingDir,
    [switch]$ForceRefetch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ── PREFLIGHT ───────────────────────────────────────────────────────────────

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "Requires PowerShell 7+. Current: $($PSVersionTable.PSVersion)"
}
Write-Host "[PREFLIGHT] pwsh $($PSVersionTable.PSVersion)"

$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

if (-not $SeedCsv)    { $SeedCsv    = Join-Path $OutDir 'canonical\nbs_pib_seeds.csv' }
if (-not $StagingDir) { $StagingDir = Join-Path $OutDir 'india_pib_nbs' }
if (-not (Test-Path $StagingDir)) { New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null }

if (-not (Test-Path $SeedCsv)) {
    throw "Seed CSV not found: $SeedCsv. See data/canonical/nbs_pib_seeds.csv for format."
}

$pythonExe = (Get-Command python -ErrorAction SilentlyContinue)?.Source
if (-not $pythonExe) { throw "python not on PATH. Install Python 3.11+ with pandas + beautifulsoup4 + lxml + pyarrow." }
Write-Host "[PREFLIGHT] python: $pythonExe"

$retrievedAt   = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$ratesCsv      = Join-Path $OutDir 'india_pib_nbs_rates.csv'
$ratesParquet  = Join-Path $OutDir 'india_pib_nbs_rates.parquet'
$diagnosticCsv = Join-Path $OutDir 'india_pib_nbs_diagnostic.csv'

# ── HELPER: retry wrapper (matches Refresh-FertilizerMarket.ps1 idiom) ──────

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

# ── READ SEED ───────────────────────────────────────────────────────────────

# Import-Csv comments out lines starting with #, so the explanatory comments in the
# seed file are filtered by Where-Object on the prid column being numeric.
$seedRows = @(
    Import-Csv -Path $SeedCsv |
        Where-Object { $_.prid -match '^\d+$' }
)
if ($seedRows.Count -eq 0) {
    Write-Warning "Seed CSV has no PRID rows. Populate $SeedCsv and re-run."
    Write-Warning "See header comments in the seed file for instructions."
    exit 0
}
Write-Host "[SEED] $($seedRows.Count) PRID(s) to process from $SeedCsv"

# ── FETCH HTML ──────────────────────────────────────────────────────────────

# PIB serves two URL templates for the same content. We try the modern one first
# and fall back to the legacy aspx if the response is suspiciously small.
$urlTemplates = @(
    'https://pib.gov.in/PressReleasePage.aspx?PRID={0}'
    'https://pib.gov.in/PressReleseDetailm.aspx?PRID={0}'
)

$fetched = @()
foreach ($row in $seedRows) {
    $prid = $row.prid
    $htmlPath = Join-Path $StagingDir "pib_$prid.html"

    if ((Test-Path $htmlPath) -and (-not $ForceRefetch)) {
        $size = (Get-Item $htmlPath).Length
        Write-Host "[FETCH] PRID=$prid cached ($([math]::Round($size/1KB,1)) KB) — skip"
        $fetched += [pscustomobject]@{ prid=$prid; html_path=$htmlPath; status='cached'; row=$row }
        continue
    }

    $ok = $false
    foreach ($tpl in $urlTemplates) {
        $url = $tpl -f $prid
        try {
            Invoke-WithRetry -Label "pib-$prid" -Max 3 -BackoffSec 5 -Script {
                Invoke-WebRequest -Uri $url -OutFile $htmlPath -UseBasicParsing -TimeoutSec 60 `
                    -UserAgent 'Mozilla/5.0 (compatible; fertilizer-market-canonical/1.0)'
            }
            $size = (Get-Item $htmlPath).Length
            if ($size -lt 4KB) {
                Write-Warning "[FETCH] PRID=$prid from $url returned only $size bytes — trying fallback URL"
                continue
            }
            Write-Host "[FETCH] PRID=$prid → $htmlPath ($([math]::Round($size/1KB,1)) KB) from $url"
            $fetched += [pscustomobject]@{ prid=$prid; html_path=$htmlPath; status='fetched'; row=$row }
            $ok = $true
            break
        } catch {
            Write-Warning "[FETCH] PRID=$prid via $url failed: $($_.Exception.Message)"
        }
    }
    if (-not $ok) {
        $fetched += [pscustomobject]@{ prid=$prid; html_path=$null; status='failed'; row=$row }
    }
    Start-Sleep -Milliseconds 800  # be polite to pib.gov.in
}

$fetchedOk = @($fetched | Where-Object { $_.html_path })
if ($fetchedOk.Count -eq 0) {
    Write-Warning "No HTML successfully fetched. Aborting parse."
    exit 1
}

# Emit a manifest the Python parser will read.
$manifestPath = Join-Path $StagingDir '_manifest.json'
$manifest = $fetchedOk | ForEach-Object {
    @{
        prid           = $_.prid
        html_path      = $_.html_path
        announced_date = $_.row.announced_date
        season         = $_.row.season
        fiscal_year    = $_.row.fiscal_year
        notes          = $_.row.notes
    }
}
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4 -Compress))

# ── PARSE (embedded Python) ─────────────────────────────────────────────────

$pyScript = @'
import json, re, sys, argparse
from pathlib import Path
import pandas as pd

try:
    from bs4 import BeautifulSoup
except ImportError:
    print("FATAL: pip install beautifulsoup4 lxml", file=sys.stderr); sys.exit(2)

ap = argparse.ArgumentParser()
ap.add_argument('--manifest',     required=True)
ap.add_argument('--out-rates',    required=True)
ap.add_argument('--out-parquet',  required=True)
ap.add_argument('--out-diag',     required=True)
ap.add_argument('--retrieved-at', required=True)
args = ap.parse_args()

manifest = json.loads(Path(args.manifest).read_text(encoding='utf-8'))
retrieved_at = args.retrieved_at

PRICE_COLS = ['source','source_record_id','country_iso3','country_name','product','product_grade',
              'market_level','year','month','price_usd_per_t','price_local_per_t','currency',
              'source_url','retrieved_at','review_flags']

# Recognised nutrient labels that appear in PIB NBS tables. PIB releases use a mix
# of "Nitrogen (N)" / "N" / "Phosphate (P)" / "P2O5" / "Potash (K)" / "K2O" / "Sulphur (S)".
NUTRIENT_PATTERNS = {
    'N': r'\b(nitrogen|^n$|\bn\b)\b',
    'P': r'\b(phosphor|phosphat|p2o5|^p$|\bp\b)\b',
    'K': r'\b(potash|potassi|k2o|^k$|\bk\b)\b',
    'S': r'\b(sulphur|sulfur|^s$|\bs\b)\b',
}

def classify_nutrient(label):
    s = str(label).strip().lower()
    for nut, pat in NUTRIENT_PATTERNS.items():
        if re.search(pat, s, re.I): return nut
    return None

def month_from_season(season, announced_date):
    # Kharif rates take effect 1 April; rabi rates take effect 1 October.
    s = (season or '').strip().lower()
    if s == 'kharif': return 4
    if s == 'rabi':   return 10
    # Fallback: use the announcement month if season missing.
    if announced_date:
        try: return int(announced_date.split('-')[1])
        except: pass
    return None

def year_from_fy(fy, announced_date, season):
    # Indian fiscal year "2023-24" maps to calendar year 2023 for kharif (Apr-Sept)
    # and 2023 for rabi-of-FY (Oct-Mar straddles 2023 and 2024 — we use the start year).
    if fy and re.match(r'^\d{4}', str(fy)):
        return int(str(fy)[:4])
    if announced_date:
        try: return int(announced_date.split('-')[0])
        except: pass
    return None

def parse_money_per_kg(cell_text):
    # PIB tables typically express NBS rates as Rs/kg with formats like:
    #   "47.02", "Rs. 47.02", "Rs 47.02 per kg", "₹47.02"
    # Some older releases use Rs/MT — caller flags those for review.
    if cell_text is None: return None
    s = re.sub(r'[,\s₹]', '', str(cell_text))
    s = re.sub(r'^(rs\.?|inr|₹)', '', s, flags=re.I)
    m = re.search(r'-?\d+(?:\.\d+)?', s)
    if not m: return None
    try: return float(m.group(0))
    except: return None

rows = []
diag = []

for entry in manifest:
    prid = entry['prid']
    html_path = entry['html_path']
    announced_date = entry.get('announced_date') or ''
    season = entry.get('season') or ''
    fy = entry.get('fiscal_year') or ''
    notes = entry.get('notes') or ''
    source_url = f'https://pib.gov.in/PressReleasePage.aspx?PRID={prid}'

    diag_entry = {'prid': prid, 'announced_date': announced_date, 'season': season,
                  'tables_found': 0, 'nutrient_rows': 0, 'status': '', 'reason': ''}

    try:
        html = Path(html_path).read_text(encoding='utf-8', errors='replace')
    except Exception as e:
        diag_entry['status'] = 'read_failed'; diag_entry['reason'] = str(e)
        diag.append(diag_entry); continue

    soup = BeautifulSoup(html, 'lxml')
    tables = soup.find_all('table')
    diag_entry['tables_found'] = len(tables)

    yr = year_from_fy(fy, announced_date, season)
    mo = month_from_season(season, announced_date)

    if yr is None or mo is None:
        diag_entry['status'] = 'skipped'
        diag_entry['reason'] = 'cannot resolve effective year/month from seed row'
        diag.append(diag_entry); continue

    nutrient_rows_this = 0
    for tbl_idx, tbl in enumerate(tables):
        # Find a row where the first cell is a nutrient label and a numeric rate follows.
        for tr in tbl.find_all('tr'):
            cells = [td.get_text(' ', strip=True) for td in tr.find_all(['td','th'])]
            if len(cells) < 2: continue
            nut = classify_nutrient(cells[0])
            if not nut: continue
            # Try each subsequent cell, take the first one that parses as a number.
            rate = None
            for c in cells[1:]:
                v = parse_money_per_kg(c)
                if v is not None and v > 0:
                    rate = v; break
            if rate is None: continue

            # NBS rates are nearly always Rs/kg. If the magnitude looks like Rs/MT
            # (i.e. > 1000) we still emit it but flag for review.
            flags = ['parsed_from_html']
            if rate > 1000:
                flags.append('magnitude_suspect_inr_per_mt')

            rows.append({
                'source':           'india_pib_nbs',
                'source_record_id': f'pib_nbs|{prid}|{nut}|{yr}-{mo:02d}',
                'country_iso3':     'IND',
                'country_name':     'India',
                'product':          nut,
                'product_grade':    None,
                'market_level':     'subsidy_inr_per_kg',
                'year':             yr,
                'month':            mo,
                'price_usd_per_t':  None,
                'price_local_per_t': rate * 1000.0,  # kg → tonne
                'currency':         'INR',
                'source_url':       source_url,
                'retrieved_at':     retrieved_at,
                'review_flags':     ';'.join(flags) + (f';table_idx={tbl_idx}'),
            })
            nutrient_rows_this += 1

    diag_entry['nutrient_rows'] = nutrient_rows_this
    if nutrient_rows_this == 0:
        diag_entry['status'] = 'no_rates_found'
        diag_entry['reason'] = f'{len(tables)} table(s) parsed but none matched nutrient row pattern; manual_extract_required'
        # Emit a placeholder row so downstream sees the PRID exists with manual_extract_required flag.
        rows.append({
            'source':           'india_pib_nbs',
            'source_record_id': f'pib_nbs|{prid}|UNRESOLVED|{yr}-{mo:02d}',
            'country_iso3':     'IND',
            'country_name':     'India',
            'product':          None,
            'product_grade':    None,
            'market_level':     'subsidy_inr_per_kg',
            'year':             yr,
            'month':            mo,
            'price_usd_per_t':  None,
            'price_local_per_t': None,
            'currency':         'INR',
            'source_url':       source_url,
            'retrieved_at':     retrieved_at,
            'review_flags':     'manual_extract_required',
        })
    else:
        diag_entry['status'] = 'parsed'
    diag.append(diag_entry)

df = pd.DataFrame(rows, columns=PRICE_COLS)
df.to_csv(args.out_rates, index=False)
df.to_parquet(args.out_parquet, index=False)

dd = pd.DataFrame(diag)
dd.to_csv(args.out_diag, index=False)

resolved = (df['product'].notna()).sum()
unresolved = (df['product'].isna()).sum()
print(f'parse complete: {len(manifest)} PRIDs, {resolved} resolved nutrient rows, {unresolved} unresolved PRIDs', file=sys.stderr)
'@

$pyTmp = Join-Path ([System.IO.Path]::GetTempPath()) "nbs_parse_$(Get-Random).py"
[System.IO.File]::WriteAllText($pyTmp, $pyScript)
try {
    & $pythonExe $pyTmp `
        --manifest     $manifestPath `
        --out-rates    $ratesCsv `
        --out-parquet  $ratesParquet `
        --out-diag     $diagnosticCsv `
        --retrieved-at $retrievedAt
    if ($LASTEXITCODE -ne 0) { throw "Python parser exited $LASTEXITCODE" }
} finally {
    Remove-Item $pyTmp -Force -ErrorAction SilentlyContinue
}

# ── LOG ─────────────────────────────────────────────────────────────────────

if (Test-Path $ratesCsv) {
    $rateRows = @(Import-Csv $ratesCsv)
    $resolved = @($rateRows | Where-Object { $_.product }).Count
    $unresolved = $rateRows.Count - $resolved
    Write-Host ""
    Write-Host "[DONE] $($rateRows.Count) row(s) in $ratesCsv"
    Write-Host "       resolved nutrient rates: $resolved"
    Write-Host "       unresolved (manual_extract_required): $unresolved"
    Write-Host "[DONE] diagnostic: $diagnosticCsv"
    Write-Host ""
    Write-Host "Review india_pib_nbs_rates.csv before any Databricks push. NBS rates"
    Write-Host "vary by season — eyeball that table_idx + extracted values match the"
    Write-Host "press release for each PRID. Rows flagged 'magnitude_suspect_inr_per_mt'"
    Write-Host "need human confirmation that the source table was Rs/kg, not Rs/MT."
}
