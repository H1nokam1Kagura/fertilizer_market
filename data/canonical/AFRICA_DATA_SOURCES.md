# Africa focus-country fertilizer data sources

**Focus countries (BB2 PSH/biofertilizer portfolio):** Ethiopia, Ghana, Kenya, Nigeria, Senegal, Tanzania.

**Last audit:** 2026-05-23. **Author:** Neil Hausmann (claude-assisted).

This document logs what's actually reachable, what's blocked, and how to extend `fertilizer_use` / `fertilizer_price` with country-specific data that goes beyond the regional/global sources already in `scripts/refresh.py`.

## TL;DR

| Country | Best automated path | Best manual path | Status |
|---|---|---|---|
| ETH | None | ESS Agricultural Sample Survey (PDF) | Blocked — PDF only, microdata registration-walled |
| GHA | None | MoFA PFJ publications (PDF) + Ghana Open Data CKAN (sparse) | Blocked — same pattern |
| KEN | None | KilimoSTAT HTML (no API), KNBS Statistical Abstract (PDF) | Blocked — KIAMIS deep links farmer-auth gated |
| NGA | AfricaFertilizer/VIFAA retail prices (already wired) | NBS NASC 2022 Community/Household XLSX (WB Microdata mirror, free, no auth) | Manual-import (XLSX is structural — fertilizer-shop access not consumption tonnes; lower value) |
| SEN | None | DAPSA EAA reports (PDF) | Blocked — PDF only, no XLSX |
| TZA | AfricaFertilizer/VIFAA retail prices (already wired) | NBS AASS Key Findings PDF | Manual-import via PDF tables (year-to-year layout drift) |

**Verdict:** None of the six focus countries publishes machine-readable, scriptable national fertilizer data the way India does on `data.gov.in`. The agent's optimism about the Knoema-style `*.opendataforafrica.org` mirrors was wrong — those sites are behind a Cloudflare JS challenge that scripted clients can't pass.

The realistic path forward is a **manual-import CSV pattern**: an analyst pulls a PDF or microdata file once a year, copies the relevant table rows into a tracked CSV in `data/canonical/`, commits the CSV, and `scripts/refresh.py` reads it like any other source. Same pattern as `data/canonical/nbs_pib_seeds.csv` for India PIB.

## Why automated wire-up doesn't work for these countries

### Cloudflare JS challenge on `opendataforafrica.org`

The agent's report flagged Knoema-style mirrors at `nigeria.opendataforafrica.org`, `senegal.opendataforafrica.org`, `kenya.opendataforafrica.org`, `tanzania.opendataforafrica.org`, `ethiopia.opendataforafrica.org`. Probe (2026-05-23):

```
curl -sSI 'https://nigeria.opendataforafrica.org/spniqxb/nigeria-fertilizer-consumption'
# → HTTP/1.1 403 Forbidden + Cloudflare JS challenge page

curl -sS 'https://nigeria.opendataforafrica.org/api/1.0/data/spniqxb'
# → Cloudflare 'Just a moment...' HTML challenge with _cf_chl_tk token
```

The challenge requires executing JavaScript + storing a session cookie. CI runners can't pass it without a headless browser (Playwright/Selenium), which adds 5+ minutes to every refresh and is itself rate-limited / fingerprinted. **Hard non-starter.**

### Direct ministry sites are PDF or login-gated

**SEN — `dapsa.gouv.sn`:** 200 OK, but `/statistiques` returns 404; the public artifacts are PDFs under `/sites/default/files/publications/*.pdf` (e.g. `Les%20exploitations%20agricoles%20de%20type%20familial%20au%20Sénégal1.pdf`). No structured XLSX export.

**TZA — `nbs.go.tz`:** 200 OK. Statistics pages list "Annual Agricultural Sample Surveys", "Agriculture Census 2019/20", "Agriculture Census 2007/08", "Food Balance Sheets" — but all linked artifacts are PDFs. Key Findings reports are public direct downloads:
- `https://www.nbs.go.tz/uploads/statistics/documents/en-1734966261-AASS%202022-23%20KEY%20FINDINGS%20REPORT-ENGLISH.pdf`
- `https://www.nbs.go.tz/uploads/statistics/documents/en-1760643333-KEY%20FINDINGS%20REPORT_AASS%202023-24_ENGLISH.pdf`
The actual fertilizer-application percentages are in tables inside these PDFs. Extraction requires `pdfplumber`/`camelot`, brittle to layout drift.

**NGA — `nigerianstat.gov.ng`:** 200 OK. NBS eLibrary search returns the NASC 2022 report at `/elibrary/read/1241525` (PDF). The microdata.nigerianstat.gov.ng portal hosts the dataset under `/index.php/catalog/79` but the actual XLSX downloads are mirrored on World Bank Microdata at `https://microdata.worldbank.org/catalog/6384/download/<file_id>` — **directly downloadable without auth**. Two files inspected (2026-05-23):
- `NASC_Household_Listing_Tables_Publication_Final_17032024.xlsx` (391 KB, 100+ sheets) — demographic structure only, no fertilizer use data.
- `NASC_Community_Tables_ALL.xlsx` (similar size, 103 sheets) — Table 14 has "Input supplier - Fertiliser shop" counts by state (proxy for distribution access, not consumption).

Neither contains fertilizer-consumption-in-tonnes-by-state. The NBS publication "Nigerian Fertilizer Consumption 1994-2010 and 2011-2015" (referenced in the agent's report) is presumably available somewhere on the NBS site but I did not find a direct URL.

**ETH, GHA, KEN:** No structured open-data portals. CSA/ESS (ETH), GSS (GHA), KNBS (KEN) all publish PDFs and host microdata behind free registration (NADA/IHSN). KilimoSTAT (KEN MoALD) has HTML tables but no CSV export.

### Microdata registration walls

`microdata.nbs.go.tz` (TZA), `microdata.nigerianstat.gov.ng` (NGA), `microdata.statsghana.gov.gh` (GHA), `microdata.worldbank.org` (all six) follow the NADA pattern — free registration to download SPSS/STATA microdata files. **Not script-compatible** without storing credentials in CI.

The one exception: WB Microdata's NASC 2022 (NGA, catalog/6384) exposes the published aggregate XLSX tables (NASC_Household_Listing_Tables_Publication and NASC_Community_Tables_ALL) without login. Those are the files probed above — useful for non-fertilizer purposes but not for `fertilizer_use`.

### What about AfricaFertilizer's per-country supplements?

The agent flagged "Fertilizer Statistics Overview" PDFs (e.g. `Nigeria 2018-2022`) hosted on IFDC's DSpace repo at `api.hub.ifdc.org/server/api/core/bitstreams/<uuid>`. These are scholarly-paper-style PDFs, not a structured data API. Same PDF-extraction problem.

## Manual-import CSV pattern (the way forward)

For each country where we want country-specific data beyond the global/regional sources already wired, we maintain a tracked CSV at `data/canonical/manual_import_<country>_<topic>.csv`. The CSV columns match the canonical `fertilizer_use` schema exactly. An analyst fills it by reading the latest source PDF and copying the relevant rows. Pull request → review → merge → next refresh picks up the new rows.

**Files in this directory:**

- `nbs_pib_seeds.csv` — India PIB NBS press release IDs. Parsed by `scripts/refresh_nbs.py` into `india_pib_nbs_rates.parquet`. **Working since 2026-05-22.**
- `manual_import_nga_consumption.csv` — Nigeria fertilizer consumption (state × year × nutrient). Source = NBS publication TBD. **Header only.**
- `manual_import_sen_consumption.csv` — Senegal fertilizer consumption (national × year × nutrient + subsidy allocation by crop). Source = DAPSA EAA PDFs. **Header only.**
- `manual_import_tza_consumption.csv` — Tanzania fertilizer consumption (region × year × nutrient). Source = NBS AASS Key Findings PDFs. **Header only.**

### Workflow

1. Analyst opens the source PDF for the country/year.
2. Locates the fertilizer table (commonly section 5 or 6 of an Annual Agricultural Survey).
3. Copies the relevant rows into the canonical CSV in this folder, **preserving the schema** (one row per country × state × year × nutrient).
4. Commits the CSV with a message like `data: TZA AASS 2023-24 fertilizer use (Mainland, by region)` and the source PDF URL in the commit body.
5. Next refresh run (manual `python scripts/refresh.py` or the weekly CI job) picks up the new rows automatically.

### Schema rules

Every row in a manual-import CSV must populate **all 13 columns** of the canonical `fertilizer_use` schema. Required values:

- `source` — `manual_import_<country>_<topic>` (e.g. `manual_import_tza_aass`)
- `source_record_id` — globally unique key: `<source>|<iso3>|<region>|<nutrient>|<year>`
- `country_iso3` — ISO-3166 alpha-3 (ETH, GHA, KEN, NGA, SEN, TZA)
- `country_name` — full country name in English
- `state_or_region` — sub-national name, or NULL for national rows
- `year` — calendar year of effect (start year of agricultural-year ranges, e.g. `2023` for 2023/24 season)
- `nutrient` — one of `N`, `P2O5`, `K2O`, `total`
- `total_tonnes` — value in metric tonnes, NULL if only kg/ha reported
- `kg_per_ha_arable` — value in kg/ha, NULL if only tonnes reported
- `arable_land_ha` — denominator if kg/ha is reported, else NULL
- `source_url` — URL of the source PDF (must resolve)
- `retrieved_at` — ISO-8601 timestamp when the analyst extracted the data
- `review_flags` — `manual_import` + any free-text caveats (semicolon-separated)

### Known canary findings worth landing first

Once an analyst has time to fill the seeds, these are the highest-leverage rows to land:

**TZA (AASS 2023-24 Key Findings, PDF):**
- 30.8% of total planted area was applied with fertilizer in 2023-24 (vs 29.9% household, 58.7% large-scale).
- Regional breakdown is in the report — would land as 25+ region-year rows.

**NGA (NASC 2022 Community Tables, XLSX — direct download from WB Microdata):**
- Communities with fertilizer-shop access: Kano 607, Katsina 542, Kaduna 437, Jigawa 368 (top 4). This is access-proxy, not consumption.
- To get consumption, the older NBS publication (1994-2015) would need to be located.

**SEN (DAPSA EAA, PDF):**
- Senegal's e-Subvention program publishes annual subsidy allocations by crop. Worth landing as a price-side row with `market_level='subsidy_total_xof_total'` once located.

## What we did NOT wire and why

- **NGA NBS NASC 2022 Excel tables**: probed, structural data only, no fertilizer-use-in-tonnes.
- **TZA NBS AASS Key Findings PDF**: extraction would need pdfplumber/camelot; year-to-year layout drift; rejected in favor of manual CSV until annual cost justifies the engineering.
- **SEN DAPSA EAA**: PDF only; same reasoning.
- **`*.opendataforafrica.org` Knoema mirrors (all 6 countries)**: Cloudflare JS challenge, unscriptable.
- **`microdata.*.gov.{ng,tz,gh,et}` registration walls**: not in scope for CI-driven refresh.

## Update protocol for this document

- Re-audit when a new annual report drops for any of the 6 countries (typically Q1 each year).
- Update the TL;DR table if a source's access pattern changes (e.g. if an opendataforafrica mirror moves off Cloudflare).
- Append findings under "What we did NOT wire" if a new source is investigated and rejected — keep the negative results so we don't re-investigate.
