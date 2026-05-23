# AfricaFertilizer / VIFAA backend discovery

Backend domain: `https://admin.africafertilizer.org` (alias `admin.vifaakenya.org` — same backend).
Frontend SPA: `https://viz.africafertilizer.org` (and per-country sub-sites: vifaakenya.org, vifaanigeria.org, etc.)

## Status: RESOLVED 2026-05-22

The POST-returns-empty problem is solved. The SPA's webpack source map at
`https://viz.africafertilizer.org/static/js/main.220c333c.js.map` is publicly served and
unminifies the entire data-fetching layer. `apiConnector.js`, `apiUtils.js`, and
`genericModule.js` in this directory are the unminified originals.

## How the SPA actually calls the backend

```js
// apiConnector.js — every chartData POST mutates the body like this before sending:
Object.assign(params, {'countryIso': country, 'lang': languageSelected})
ApiUtils.postData(url, params)

// apiUtils.js — no auth, no cookies, no CSRF, no withCredentials:
Axios.post(`${API_ROOT_URL}${endpoint}`, data, {headers: headers})
```

So **every POST body must include `countryIso` (ISO2) and `lang`** in addition to whatever
the chart-specific filter defaults specified. That's what the prior attempt was missing.

## Canonical workflow

Three calls per (country, chart) tuple:

1. `GET /api/filtersDefaults/<chart-path>?countryIso=<ISO2>&selectedLanguage=en`
   — returns the canonical body shape (years/dates/products/towns/currency/unit) verbatim.
2. Augment that body with `countryIso: "<ISO2>"`, `lang: "en"`, and any field overrides
   (widened date range, USD instead of local currency, etc.).
3. `POST <chart-path>` with the augmented body.

Always send headers:
```
Origin: https://viz.africafertilizer.org
Referer: https://viz.africafertilizer.org/
Content-Type: application/json
Accept: application/json
```

## Schema gotchas — same endpoint family, different field names

| Endpoint | Product field | Town field |
|---|---|---|
| `/api/prices/byProducts` | `compoundProductSelected` (singular string) | `townsSelected` (array of ids, REQUIRED non-empty) |
| `/api/prices/byProductsAndDates` | `compoundProductSelected` (singular) | `townsSelected` (array) |
| `/api/prices/seriesByProducts` | `compoundProductsSelected` (PLURAL array of strings) | `townSelected` (singular int, e.g. `0`) |

Currency + unit must agree (`USD`+`USD_MT`, `KES`+`KES_50_KG`, `MZN`+`MZN_50_KG`, etc.).
The native unit per country is whatever the filter-defaults GET returns.

## Verified working endpoints (POST)

```
POST /api/prices/byProducts                           — town-level current-month snapshot
POST /api/prices/byProductsAndDates                   — same as byProducts but date-windowed
POST /api/prices/seriesByProducts                     — full time series per product (canonical refresh shape)
POST /api/fob/historicalSeriesByProducts              — international FOB series (per IFDC scrapper)
POST /api/prices/comparisonYearly                     — subsidized vs commercial, yearly
POST /api/prices/comparisonMonthly                    — subsidized vs commercial, monthly
POST /api/prices/comparisonSeries                     — same comparison, time-series shape
POST /api/prices/threeMonthsComparisonConsecutivePeriods
POST /api/subsidized/<various>                        — subsidy-coverage charts
POST /api/imports/byproducts                          — import quantities by product
POST /api/exports/sankey                              — urea export flow
POST /api/cost/cbu                                    — cost build-up
POST /api/consumption/<various>                       — apparent + nutrient + product consumption
POST /api/fubc/fubcseries                             — fertilizer use by crop
POST /api/nubc/nutrientUseByCropData                  — nutrient use by crop
POST /api/crops/nationalCropsUnderProductionChart     — cropland under production
POST /api/npkProduction/<various>                     — raw NPK production (Nigeria)
POST /api/transit/<various>                           — transit / re-export
POST /api/plants                                      — fertilizer plant directory
```

Full mapping is in `apiConnector.js` (35 chart modules × { `defaultFilters`, `filters{}`,
`chartData{}`, `settings` } URLs).

## Working endpoints (GET, no body)

```
GET  /api/prices/countries                            — 19 VIFAA countries with id + ISO2
GET  /api/prices/dates/all                            — 188 monthly dates 2010-03 → 2025-12
GET  /api/prices/compoundProductsList?countryIso=KE   — per-country product catalog
GET  /api/configuration/chart/allMin?countryIso=KE&lang=en
GET  /api/fob/argusLegend
GET  /api/cost/transportTowns?countryIso=KE           — town IDs (alternative to filter-defaults)
GET  /api/filtersDefaults/<chart-path>?countryIso=<ISO2>&selectedLanguage=en
```

## Endpoints still returning empty (likely deprecated)

These showed up in the SPA bundle's endpoint mapping but consistently return `{}` or `500`
even with body shapes matching the schema in `apiConnector.js`:

- `POST /api/prices/nationalAvgPrices`
- `POST /api/prices/singleProductByCountry`

Use `byProducts` + a date loop, or `seriesByProducts`, instead.

## Priority-country ID + ISO mapping

| ISO2 | ISO3 | Country | VIFAA numeric id | In refresh scope |
|---|---|---|---|---|
| ET | ETH | Ethiopia | 120423 | yes (returned empty 2026-05-22) |
| GH | GHA | Ghana | 16 | yes |
| KE | KEN | Kenya | 24 | yes |
| MW | MWI | Malawi | 120435 | yes |
| MZ | MOZ | Mozambique | 120437 | yes |
| NG | NGA | Nigeria | 52 | yes |
| RW | RWA | Rwanda | 53653 | yes |
| SN | SEN | Senegal | 39 | yes |
| TZ | TZA | Tanzania | 120429 | yes |
| UG | UGA | Uganda | 120431 | yes |
| ZM | ZMB | Zambia | 120439 | yes |

Zimbabwe (ZWE) is **not** in the VIFAA dataset. Côte d'Ivoire, Burkina Faso, Mali, Cameroon,
Benin are in the country list but not in the current refresh scope.

## Key product IDs (stable across countries)

| ID | Product | Canonical name in repo |
|---|---|---|
| 13 | Diammonium Phosphate (DAP) — 18/46/0 | dap |
| 45 | Muriate of Potash (MOP) | mop |
| 140 | NPK 17-17-17 | npk_17_17_17 |
| 203 | NPK 25-5-5 + 5S | npk_25_5_5_5s |
| 281 | Urea — 46/0/0 | urea |
| 285 | Calcium Ammonium Nitrate (CAN) — 27/0/0 | can |

Per-country product catalog varies (Kenya has 49 products; Ethiopia only 6).

## Files in this directory

| File | What it is |
|---|---|
| `apiConnector.js` | Unminified SPA module mapping every chart → endpoint paths (35 modules) |
| `apiUtils.js` | Unminified axios wrapper (proves no auth/cookies/headers needed) |
| `genericModule.js` | Unminified Redux module showing how chartData POSTs are dispatched |
| `countries.json` | 19 VIFAA countries with internal numeric id, ISO2, name, regions, lat/lon |
| `dates_all.json` | 188 monthly dates from `/api/prices/dates/all` |
| `products_by_country.json` | Per-country compound-product catalogs from `/api/prices/compoundProductsList` |
| `references/` | Reference implementations + sample probe responses |
| `references/poider_*.{js,py,md}` | Working Node/axios client from `Poider/scrapperUSAID` GitHub repo |
| `references/vipond_*.ts` | TypeScript dashboard client from `AlexVipond/kenya-fertilizer-dashboard` |
| `references/probe_*.json` | Sample probe responses (countries, products, towns, byProductsAndDates) |

## Fallback data paths (priority order)

If the live API ever breaks or goes private:

1. **DSpace 7 REST at `hub.ifdc.org`** — public DSpace. Bitstream-level access via
   `https://api.hub.ifdc.org/server/api/core/bitstreams/<UUID>/content`. Contains FertiNews
   monthly bulletins (2024+) and country-level "Fertilizer Statistics Overview" PDFs.
   Discover endpoint: `/server/api/discover/search/objects?query=FertiNews`.
2. **Harvard Dataverse `doi:10.7910/DVN/E0EHLO`** — frozen 2010-2018 snapshot, 7,823 obs,
   878 locations, 17 countries. Same underlying source.
   `https://dataverse.harvard.edu/api/access/datafile/:persistentId?persistentId=doi:10.7910/DVN/E0EHLO`
3. **AMITSA legacy XLSX archive at `africafertilizer.org/wp-content/uploads/<YYYY>/<MM>/AMITSA-<COUNTRY>-monthly-price-report-<MMM>-<YYYY>.xlsx`** — enumerable URL pattern. Patchy.

## Notes on auth

There is no public OAS/Swagger or developer portal. `/swagger-ui.html`, `/v3/api-docs`,
`/api-docs`, and `/openapi.json` all 302 to `/login` (admin-only). The public `/api/*`
endpoints are CORS-open with the right `Origin`/`Referer` — no key, no cookie. For partner
data-sharing agreements: info@africafertilizer.org (IFDC/Development Gateway).

## Next time the SPA hash changes

If `viz.africafertilizer.org` ships a new bundle and the endpoint mapping shifts, fetch
the fresh sourcemap from whatever `<script src="/static/js/main.*.js">` is in the page's
HTML, append `.map`, and re-extract `apiConnector.js` from `sourcesContent`. The
`asset-manifest.json` at the same site lists all chunk URLs.
