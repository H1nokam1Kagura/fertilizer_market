-- fertilizer_market — Unity Catalog DDL (Azure ggo_agdev workspace)
-- Each statement fully-qualified so it works with the one-statement-per-call SQL Statements API.
-- Run via: pwsh -File .\databricks\Load-FertilizerMarket.ps1 -CreateTables

CREATE TABLE IF NOT EXISTS ggo_agdev.bioinputs.fertilizer_price (
  source              STRING  COMMENT 'wb_pinksheet | africafertilizer | india_dof | ifdc_aaw',
  source_record_id    STRING  COMMENT 'Composite key: source + product + iso3 + year-month',
  country_iso3        STRING  COMMENT 'NULL for global benchmarks (Pink Sheet)',
  country_name        STRING,
  product             STRING  COMMENT 'urea | dap | mop | tsp | npk_15_15_15 | ammonia | phosphate_rock',
  product_grade       STRING  COMMENT 'granular | prilled | bulk_blend | bagged | …',
  market_level        STRING  COMMENT 'global_fob | landed_cif | wholesale | retail',
  year                INT,
  month               INT     COMMENT '1-12',
  price_usd_per_t     DOUBLE,
  price_local_per_t   DOUBLE  COMMENT 'NULL for global benchmarks',
  currency            STRING  COMMENT 'ISO 4217',
  source_url          STRING,
  retrieved_at        STRING  COMMENT 'ISO-8601 UTC',
  review_flags        STRING  COMMENT 'Semicolon-separated QC codes; same convention as ref_varieties'
) USING DELTA
PARTITIONED BY (year)
TBLPROPERTIES (
  'delta.feature.allowColumnDefaults' = 'enabled',
  'comment' = 'Monthly fertilizer prices. Sources: WB Pink Sheet global benchmarks, AfricaFertilizer country retail, (v2) India DOF + IFDC AAW. Weekly refresh.'
);

CREATE TABLE IF NOT EXISTS ggo_agdev.bioinputs.fertilizer_use (
  source              STRING  COMMENT 'faostat | faostat_product | owid | wb_wdi | india_dof_consumption | india_dof_state_consumption | india_dof_district_npk',
  source_record_id    STRING  COMMENT 'source + iso3 + nutrient + year (+ state/district if sub-national)',
  country_iso3        STRING,
  country_name        STRING,
  state_or_region     STRING  COMMENT 'Sub-national name (Indian state/UT, district, US state, etc.). NULL for national rows.',
  year                INT,
  nutrient            STRING  COMMENT 'N | P2O5 | K2O | total',
  total_tonnes        DOUBLE  COMMENT 'NULL if only kg/ha reported',
  kg_per_ha_arable    DOUBLE  COMMENT 'Canonical metric for taxonomies',
  arable_land_ha      DOUBLE  COMMENT 'Denominator used for kg/ha',
  source_url          STRING,
  retrieved_at        STRING,
  review_flags        STRING
) USING DELTA
PARTITIONED BY (year)
TBLPROPERTIES (
  'delta.feature.allowColumnDefaults' = 'enabled',
  'comment' = 'Annual fertilizer use by country (and optionally sub-national region) and nutrient. Sources: FAOSTAT RFN + FAOSTAT Product P2O5/K2O cross-check, OWID, WB WDI, India DoF (national + state-year + district-year). Weekly refresh.'
);
