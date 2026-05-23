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
| **India FAI Yearbook (PDF)** | **DROPPED** — no PDF scrape | Replace with structured sources: (1) `desagri.gov.in` Table 14.4(a) state-wise N/P/K consumption (PDF + Excel, annual, **geo-blocked from US** → needs India-resident runner or VPN); (2) `data.gov.in` Dept-of-Fertilizers via REST + public guest API key — **annual subsidy + annual all-India consumption now wired** in puller as of 2026-05-22 evening; (3) Cost of Cultivation Survey (CCS) via `eands.dacnet.nic.in` for the per-crop allocation. **ICRISAT DLD was originally listed here but is incorrect** — investigated 2026-05-22 evening, ICRISAT publishes aggregate seasonal N/P/K by district, **NOT per-crop**. CCS is the only open per-crop source. |
| **India DOF Monthly Bulletin (PDF)** | **KEEP** — only path to monthly MRP / monthly sales | Layer two supplementary sources alongside it: (a) `data.gov.in` annual subsidy + consumption (now wired, source = `india_dof_subsidy` + `india_dof_consumption`); (b) PIB press-release scraper for NBS rate-change events — **first run completed 2026-05-22** (`Refresh-IndiaNBS.ps1` seeded with 9 PRIDs 2021-2025). 3/9 PRIDs parsed cleanly → 12 N/P/K/S rates (Rabi 2021-22, Rabi 2022-23, Rabi 2023-24). 6/9 flagged `manual_extract_required` — **format change**: from Kharif 2022 onward PIB stopped including the per-nutrient rate table inline in the press release HTML; rates now live in a separate PDF annex. PDF-annex scraper is the v2 next step. |
| **DoF iFMS / e-Urvarak / mFMS** | **DEFERRED** — not a scraper task | Real-time PoS sales by state/district/retailer; login-gated; only path is a DoF data-sharing MoU. Move to a foundation-relationship workstream, not the scraper roadmap |
| **IFDC Africa Fertilizer Watch / VIFAA** | **DONE 2026-05-22** | `Get-AfricaFertilizer` rewired to `POST /api/prices/seriesByProducts` via GET-defaults-then-POST workflow. Body must include `countryIso` (ISO2 string) + `lang` + endpoint-specific product field (singular `compoundProductSelected` vs plural `compoundProductsSelected`). Reverse-engineered from `viz.africafertilizer.org/static/js/main.220c333c.js.map` — full unminified API client + 35-chart endpoint mapping in `data/_afe_discovery/`. First pull: 3,668 rows, 10/11 priority countries. Ethiopia still empty on this endpoint (needs `/byProductsAndDates` fallback — open chad). |

## Notable findings (2026-05-22)

### Full N / P2O5 / K2O kg/ha-arable breakdown, 2023 (FAOSTAT direct)

| Country | N | P2O5 | K2O | Total (OWID) |
|---|---|---|---|---|
| CHN | 192.39 | 73.40 | 69.08 | 394.02 |
| IND | 121.53 | 49.35 | 11.16 | 199.14 |
| BRA | 90.92 | 69.99 | 124.43 | 344.09 |
| ZAF | 30.50 | 21.67 | 14.99 | 77.19 |
| **ETH** | 29.65 | **10.51** | 0.11 | 45.32 |
| KEN | 22.31 | 13.47 | 9.03 | 50.46 |
| TZA | 12.12 | 4.81 | 1.08 | 20.71 |
| NGA | 1.99 | 1.03 | 0.52 | 4.24 |
| UGA | 1.28 | 0.55 | 0.70 | 3.33 |

### Ethiopia P-stress callout

Ethiopia has the **steepest P-fertilizer dependency in Tier-1 SSA** (10.51 kg P2O5/ha — 3rd
highest globally after BRA + CHN among the 9 baseline countries, ahead of even KEN and ZAF).
If DAP prices spike per the Iran/Hormuz scenario, **ETH is the most exposed market in the BB2
priority set**. PSO products (INITIA, Biotango) become the highest-leverage play here — not
just NFX. Today's BB2 portfolio has zero ongoing PSO products allocated to Ethiopia.

### Tier-1 SSA N-baselines are catastrophically below the 20 kg/ha TPP

OWID revised Nigeria (11.78 → 4.24 kg/ha total) and Uganda (9.29 → 3.33) downward in 2024.
The FAOSTAT N component is even lower: NGA 1.99 kg N/ha, UGA 1.28 kg N/ha. The 20 kg/ha N
TPP is **3-4× current N application** in those markets, not displacement. A "first kg of N"
framing fits the data; a 20 kg displacement framing does not.

### FAOSTAT metadata gotcha

The FAOSTAT RFN bulk `Inputs_FertilizersNutrient_E_ItemCodes.csv` lists only Item Code 3102
(Nitrogen). The data CSV itself actually contains 3102 (N), 3103 (P2O5), and 3104 (K2O) —
the metadata file is stale. **Don't trust FAOSTAT's `ItemCodes.csv`; probe the data CSV
directly.** This bug cost a day; the original "FAOSTAT has no P+K" diagnosis was wrong.

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
