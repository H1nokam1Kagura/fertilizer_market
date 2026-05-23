<#
.SYNOPSIS
    Test-Smoke.ps1 — Pester smoke test for fertilizer_market repo. Validates the two
    parquet artifacts exist, match expected schemas, contain rows from ≥3 sources, and
    pass basic data-shape invariants.

.DESCRIPTION
    Invoke locally:
        Invoke-Pester .\tests\Test-Smoke.ps1
    or from the repo root in CI:
        pwsh -NoProfile -Command "Invoke-Pester ./tests/Test-Smoke.ps1 -Output Detailed"

    Reads parquets via embedded Python (pandas + pyarrow) — same dependency set as the
    refresh script.

.NOTES
    Requires: pwsh 7+, Python 3.11+ with pandas + pyarrow, Pester 5+.
#>

Describe 'fertilizer_market artifacts' {

    BeforeAll {
        $script:repoRoot      = Split-Path -Parent $PSScriptRoot
        $script:pricesParquet = Join-Path $script:repoRoot 'data\prices.parquet'
        $script:useParquet    = Join-Path $script:repoRoot 'data\use.parquet'
        $script:py = (Get-Command python -ErrorAction Stop).Source
        $script:summaryScript = @'
import json, sys, pandas as pd
p = pd.read_parquet(sys.argv[1])
print(json.dumps({
    "rows": int(len(p)),
    "cols": list(p.columns),
    "sources": p["source"].value_counts().to_dict() if "source" in p.columns else {},
    "year_min": int(p["year"].min()) if "year" in p.columns and len(p) else None,
    "year_max": int(p["year"].max()) if "year" in p.columns and len(p) else None,
    "iso3_n":   int(p["country_iso3"].dropna().nunique()) if "country_iso3" in p.columns else 0,
}))
'@
        $script:tmpPy = Join-Path ([System.IO.Path]::GetTempPath()) "fertest_$(Get-Random).py"
        [System.IO.File]::WriteAllText($tmpPy, $summaryScript)

        function Get-ParquetSummary {
            param([string]$Path)
            $raw = & $script:py $script:tmpPy $Path
            return ($raw | ConvertFrom-Json)
        }
    }

    AfterAll {
        Remove-Item $script:tmpPy -Force -ErrorAction SilentlyContinue
    }

    Context 'prices.parquet' {
        It 'exists' {
            Test-Path $script:pricesParquet | Should -BeTrue
        }
        It 'has the canonical 15 columns' {
            $s = Get-ParquetSummary -Path $script:pricesParquet
            $expected = @('source','source_record_id','country_iso3','country_name','product','product_grade',
                          'market_level','year','month','price_usd_per_t','price_local_per_t','currency',
                          'source_url','retrieved_at','review_flags')
            $s.cols | Should -Be $expected
        }
        It 'contains at least 5000 rows (Pink Sheet + AFE together)' {
            (Get-ParquetSummary -Path $script:pricesParquet).rows | Should -BeGreaterThan 5000
        }
        It 'contains both wb_pinksheet AND africafertilizer' {
            $sources = (Get-ParquetSummary -Path $script:pricesParquet).sources.PSObject.Properties.Name
            $sources | Should -Contain 'wb_pinksheet'
            $sources | Should -Contain 'africafertilizer'
        }
        It 'has Ethiopia absent in africafertilizer (known VIFAA upstream data gap)' {
            $py = @'
import sys, pandas as pd
p = pd.read_parquet(sys.argv[1])
afe = p[p["source"] == "africafertilizer"]
print("YES" if (afe["country_iso3"] == "ETH").any() else "NO")
'@
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "fertest_eth_$(Get-Random).py"
            [System.IO.File]::WriteAllText($tmp, $py)
            try {
                (& $script:py $tmp $script:pricesParquet).Trim() | Should -Be 'NO'
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'use.parquet' {
        It 'exists' {
            Test-Path $script:useParquet | Should -BeTrue
        }
        It 'has the canonical 12 columns' {
            $s = Get-ParquetSummary -Path $script:useParquet
            $expected = @('source','source_record_id','country_iso3','country_name','year','nutrient',
                          'total_tonnes','kg_per_ha_arable','arable_land_ha',
                          'source_url','retrieved_at','review_flags')
            $s.cols | Should -Be $expected
        }
        It 'contains at least 80000 rows (FAOSTAT N+P+K + OWID + WDI)' {
            (Get-ParquetSummary -Path $script:useParquet).rows | Should -BeGreaterThan 80000
        }
        It 'includes faostat as a source with all three nutrients (N, P2O5, K2O)' {
            $py = @'
import sys, pandas as pd
p = pd.read_parquet(sys.argv[1])
fao = p[p["source"] == "faostat"]
nuts = set(fao["nutrient"].dropna().unique())
need = {"N","P2O5","K2O"}
print(",".join(sorted(need - nuts)) or "OK")
'@
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "fertest_fao_$(Get-Random).py"
            [System.IO.File]::WriteAllText($tmp, $py)
            try {
                (& $script:py $tmp $script:useParquet).Trim() | Should -Be 'OK'
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
        It 'includes faostat_product cross-check rows for P2O5 + K2O' {
            $sources = (Get-ParquetSummary -Path $script:useParquet).sources.PSObject.Properties.Name
            $sources | Should -Contain 'faostat_product'
        }
        It 'includes india_dof_consumption rows (India v2 source)' {
            $sources = (Get-ParquetSummary -Path $script:useParquet).sources.PSObject.Properties.Name
            $sources | Should -Contain 'india_dof_consumption'
        }
        It 'spans more than one country' {
            (Get-ParquetSummary -Path $script:useParquet).iso3_n | Should -BeGreaterThan 1
        }
        It 'includes the priority-tier-1 countries' {
            $py2 = @'
import sys, pandas as pd
p = pd.read_parquet(sys.argv[1])
need = {'IND','NGA','ETH','TZA','KEN'}
have = set(p["country_iso3"].dropna().unique())
print(",".join(sorted(need - have)))
'@
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "fertest_t1_$(Get-Random).py"
            [System.IO.File]::WriteAllText($tmp, $py2)
            try {
                $missing = & $script:py $tmp $script:useParquet
                $missing.Trim() | Should -BeNullOrEmpty
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}
