# fertilizer_market

Canonical fertilizer **price** and **use** dataset for Gates Foundation portfolio analysis.
Public, free-source-only, refreshed weekly. Patterned on the sibling
[`crop_varieties_canonical`](https://github.com/H1nokam1Kagura/crop_varieties_canonical) repo.

## What's in here

Two artifacts in `data/`, both committed:

| File | Grain | Sources | Typical size |
|---|---|---|---|
| `prices.parquet` / `.csv` | Monthly, by product × country × market_level | WB Pink Sheet, AfricaFertilizer | ~10k rows |
| `use.parquet` / `.csv`    | Annual, by country × nutrient (N / P2O5 / K2O / total) | FAOSTAT, OurWorldInData, WB WDI | ~60k rows |

The two parquets are the single source of truth — every consumer (Databricks Delta tables,
MCP queries, ad-hoc analysis) reads from these.

## Schema

### `prices.parquet`

| column | type | notes |
|---|---|---|
| `source` | string | `wb_pinksheet` \| `africafertilizer` \| `india_dof` \| `ifdc_aaw` |
| `source_record_id` | string | composite key: source + product + iso3 + year-month |
| `country_iso3` | string | NULL for global benchmarks (Pink Sheet) |
| `country_name` | string | |
| `product` | string | `urea` \| `dap` \| `mop` \| `tsp` \| `npk_15_15_15` \| `ammonia` \| `phosphate_rock` |
| `product_grade` | string | `granular` \| `prilled` \| `bulk_blend` \| `bagged` |
| `market_level` | string | `global_fob` \| `landed_cif` \| `wholesale` \| `retail` |
| `year` | int32 | |
| `month` | int32 | 1-12 |
| `price_usd_per_t` | double | |
| `price_local_per_t` | double | NULL for global benchmarks |
| `currency` | string | ISO 4217 |
| `source_url` | string | provenance |
| `retrieved_at` | string | ISO-8601 UTC |
| `review_flags` | string | semicolon-separated QC codes |

### `use.parquet`

| column | type | notes |
|---|---|---|
| `source` | string | `faostat` \| `owid` \| `wb_wdi` \| `india_fai` |
| `source_record_id` | string | source + iso3 + nutrient + year |
| `country_iso3` | string | |
| `country_name` | string | |
| `year` | int32 | |
| `nutrient` | string | `N` \| `P2O5` \| `K2O` \| `total` |
| `total_tonnes` | double | NULL if only kg/ha reported |
| `kg_per_ha_arable` | double | canonical metric for taxonomies |
| `arable_land_ha` | double | denominator used for kg/ha |
| `source_url` | string | |
| `retrieved_at` | string | |
| `review_flags` | string | |

## Quick start

```powershell
# One-time setup (run once per machine):
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Unblock-File -Path .\scripts\Refresh-FertilizerMarket.ps1
Unblock-File -Path .\databricks\Load-FertilizerMarket.ps1
Unblock-File -Path .\databricks\Weekly-Refresh.ps1

# Confirm Databricks CLI auth (uses your existing keychain — no PATs in scripts):
databricks auth describe --profile DEFAULT

# First run — create Delta tables, no load yet:
pwsh -File .\databricks\Load-FertilizerMarket.ps1 -CreateTables -SkipLoad

# Pull data, emit parquet, push to Databricks:
pwsh -File .\scripts\Refresh-FertilizerMarket.ps1

# Or pull data only (skip Databricks push) — useful for local dev:
pwsh -File .\scripts\Refresh-FertilizerMarket.ps1 -SkipDatabricksPush

# Smoke test the artifacts:
Invoke-Pester .\tests\Test-Smoke.ps1
```

## Refresh cadence

| Path | When | What runs |
|---|---|---|
| **Primary** | Sunday 03:00 UTC | Databricks Job `fertilizer-weekly-refresh` runs `databricks/Weekly-Refresh.ps1`, which invokes `scripts/Refresh-FertilizerMarket.ps1` against the Git-folder-synced repo and writes to `ggo_agdev.bioinputs.fertilizer_*`. |
| **Backup** | Saturday 22:00 UTC | GitHub Actions `weekly-refresh.yml` runs the same `scripts/Refresh-FertilizerMarket.ps1 -SkipDatabricksPush` on `windows-latest`, opens a PR with the refreshed `data/*.parquet`. |
| **Manual fallback** | Any time | `pwsh -File .\databricks\Load-FertilizerMarket.ps1` reloads from local `data/` to Databricks. |

## Databricks targets

- **Azure (production):** `ggo_agdev.bioinputs.fertilizer_price`, `ggo_agdev.bioinputs.fertilizer_use`
- **Fairgrounds (public mirror):** `gates_open_data.open_data.fertilizer_price`, `…fertilizer_use`

Both target catalogs use the same DDL — see `databricks/create_tables.sql` and
`databricks/create_tables_fg.sql`. Load the FG mirror with:

```powershell
pwsh -File .\databricks\Load-FertilizerMarket.ps1 -Fairgrounds -Profile fairgrounds -CreateTables
```

## Sources covered (v1)

| Layer | Source | Cadence | Endpoint |
|---|---|---|---|
| Price | World Bank Pink Sheet | Monthly ~10th | `thedocs.worldbank.org/.../CMO-Historical-Data-Monthly.xlsx` |
| Price | AfricaFertilizer / VIFAA | Monthly | `admin.africafertilizer.org/api/prices/seriesByProducts` — 10/11 priority countries, ~3,700 monthly observations 2010-present. Backend reverse-engineered from SPA sourcemap; see `data/_afe_discovery/README.md` |
| Use | FAOSTAT RFN Fertilizers by Nutrient (Normalized) | Annual (Sept release, T-2) | `fenixservices.fao.org/faostat/.../Inputs_FertilizersNutrient_E_All_Data_(Normalized).zip` |
| Use | OurWorldInData fertilizer-use grapher | Annual | `ourworldindata.org/grapher/fertilizer-use-in-kg-per-hectare-of-arable-land.csv` |
| Use | World Bank WDI `AG.CON.FERT.ZS` | Annual | `api.worldbank.org/v2/country/all/indicator/AG.CON.FERT.ZS` |

## v2 source plan (locked 2026-05-22)

| Source | v2 decision | Replacement / supplement |
|---|---|---|
| **India FAI Yearbook (PDF)** | **DROPPED** — no PDF scrape | Replace with three structured sources: (1) `desagri.gov.in` Table 14.4(a) state-wise N/P/K consumption (PDF + Excel, annual, geo-blocked from US → needs India-resident runner or VPN); (2) `data.gov.in` Dept-of-Fertilizers resources via the `datagovindia` Python wrapper (CSV/JSON/REST, free API key); (3) ICRISAT District Level Data (`data.icrisat.org/dld/src/inputs.html`) for the per-crop allocation (rice/wheat/cotton/sugarcane) — the one field FAI uniquely had |
| **India DOF Monthly Bulletin (PDF)** | **KEEP** — only path to monthly MRP / monthly sales | Layer two supplementary sources alongside it: (a) `data.gov.in` annual subsidy + consumption (ground truth + reconciliation, free API key); (b) PIB press-release scraper for NBS rate-change events (semi-annual cabinet approvals → drives the subsidy/ton time series) |
| **DoF iFMS / e-Urvarak / mFMS** | **DEFERRED** — not a scraper task | Real-time PoS sales by state/district/retailer; login-gated; only path is a DoF data-sharing MoU. Move to a foundation-relationship workstream, not the scraper roadmap |
| **IFDC Africa Fertilizer Watch / VIFAA** | **DONE 2026-05-22** | `Get-AfricaFertilizer` rewired to `POST /api/prices/seriesByProducts` via GET-defaults-then-POST workflow. Body must include `countryIso` (ISO2 string) + `lang` + endpoint-specific product field (singular `compoundProductSelected` vs plural `compoundProductsSelected`). Reverse-engineered from `viz.africafertilizer.org/static/js/main.220c333c.js.map` — full unminified API client + 35-chart endpoint mapping in `data/_afe_discovery/`. First pull: 3,668 rows, 10/11 priority countries. Ethiopia still empty on this endpoint (needs `/byProductsAndDates` fallback — open chad). |

## Architecture notes

- `Refresh-FertilizerMarket.ps1` is the only puller. Embedded Python (pandas + openpyxl + pyarrow)
  handles XLSX, ZIP/CSV, JSON, and parquet serialization. PowerShell handles HTTP + orchestration +
  Databricks CLI.
- Every `databricks` CLI call is wrapped in a 3× retry and pins `--profile` explicitly.
- Idempotent: re-running is safe. `INSERT OVERWRITE` replaces the Delta partition; previous-source
  rows are preserved if a single source fails on a given run.
- Provenance: every row carries `source`, `source_url`, `retrieved_at`. QC issues go in
  `review_flags` (semicolon-separated), same convention as `ref_varieties`.
- Type discipline: `year` and `month` are `int32` on disk; cast to `INT` on Databricks load to
  avoid the INT/BIGINT drift that bit the varieties build.

## Repository layout

```
fertilizer_market/
├─ README.md
├─ data/
│  ├─ dim_country.csv
│  ├─ prices.parquet            (built by refresh)
│  ├─ prices.csv
│  ├─ use.parquet
│  ├─ use.csv
│  └─ refresh_log.csv           (append-only audit trail)
├─ scripts/
│  └─ Refresh-FertilizerMarket.ps1
├─ databricks/
│  ├─ create_tables.sql
│  ├─ create_tables_fg.sql
│  ├─ Load-FertilizerMarket.ps1
│  └─ Weekly-Refresh.ps1
├─ .github/workflows/
│  └─ weekly-refresh.yml
└─ tests/
   └─ Test-Smoke.ps1
```
