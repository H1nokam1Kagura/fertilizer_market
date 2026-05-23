-- fertilizer_market — Unity Catalog DDL (Fairgrounds gates_open_data)
-- Public-mirror target. Each statement is fully-qualified so it works with the
-- one-statement-per-call SQL Statements API (no session USE CATALOG bleed).

CREATE TABLE IF NOT EXISTS gates_open_data.open_data.fertilizer_price (
  source              STRING  COMMENT 'wb_pinksheet | africafertilizer | india_dof | ifdc_aaw',
  source_record_id    STRING  COMMENT 'Composite key: source + product + iso3 + year-month',
  country_iso3        STRING  COMMENT 'NULL for global benchmarks (Pink Sheet)',
  country_name        STRING,
  product             STRING  COMMENT 'urea | dap | mop | tsp | npk_15_15_15 | ammonia | phosphate_rock',
  product_grade       STRING,
  market_level        STRING  COMMENT 'global_fob | landed_cif | wholesale | retail',
  year                INT,
  month               INT     COMMENT '1-12',
  price_usd_per_t     DOUBLE,
  price_local_per_t   DOUBLE,
  currency            STRING,
  source_url          STRING,
  retrieved_at        STRING,
  review_flags        STRING
) USING DELTA
PARTITIONED BY (year)
TBLPROPERTIES (
  'delta.feature.allowColumnDefaults' = 'enabled',
  'comment' = 'Monthly fertilizer prices. Public Fairgrounds mirror of ggo_agdev.bioinputs.fertilizer_price.'
);

CREATE TABLE IF NOT EXISTS gates_open_data.open_data.fertilizer_use (
  source              STRING,
  source_record_id    STRING,
  country_iso3        STRING,
  country_name        STRING,
  year                INT,
  nutrient            STRING,
  total_tonnes        DOUBLE,
  kg_per_ha_arable    DOUBLE,
  arable_land_ha      DOUBLE,
  source_url          STRING,
  retrieved_at        STRING,
  review_flags        STRING
) USING DELTA
PARTITIONED BY (year)
TBLPROPERTIES (
  'delta.feature.allowColumnDefaults' = 'enabled',
  'comment' = 'Annual fertilizer use by country and nutrient. Public Fairgrounds mirror of ggo_agdev.bioinputs.fertilizer_use.'
);
