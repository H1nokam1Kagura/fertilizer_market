"""Smoke tests for canonical parquets. Runs in CI (ubuntu-latest, pytest).
Validates schema + row counts + that load-bearing sources are present.

Invoke:
    pytest tests/test_smoke.py
"""
from __future__ import annotations

from pathlib import Path

import pandas as pd
import pytest

REPO = Path(__file__).resolve().parent.parent
PRICES = REPO / "data" / "prices.parquet"
USE = REPO / "data" / "use.parquet"

PRICE_COLS = ('source', 'source_record_id', 'country_iso3', 'country_name', 'product',
              'product_grade', 'market_level', 'year', 'month', 'price_usd_per_t',
              'price_local_per_t', 'currency', 'source_url', 'retrieved_at', 'review_flags')
USE_COLS = ('source', 'source_record_id', 'country_iso3', 'country_name', 'state_or_region',
            'year', 'nutrient', 'total_tonnes', 'kg_per_ha_arable', 'arable_land_ha',
            'source_url', 'retrieved_at', 'review_flags')


@pytest.fixture(scope="session")
def prices() -> pd.DataFrame:
    assert PRICES.exists(), f"missing {PRICES}"
    return pd.read_parquet(PRICES)


@pytest.fixture(scope="session")
def use() -> pd.DataFrame:
    assert USE.exists(), f"missing {USE}"
    return pd.read_parquet(USE)


def test_prices_schema(prices: pd.DataFrame) -> None:
    assert tuple(prices.columns) == PRICE_COLS


def test_prices_minimum_rows(prices: pd.DataFrame) -> None:
    assert len(prices) > 5000, f"only {len(prices)} price rows"


def test_prices_pinksheet_and_afe(prices: pd.DataFrame) -> None:
    sources = set(prices["source"].dropna().unique())
    assert "wb_pinksheet" in sources
    assert "africafertilizer" in sources


def test_prices_ethiopia_afe_gap(prices: pd.DataFrame) -> None:
    """VIFAA has no Ethiopia retail prices — canary that the skip-list is working."""
    afe = prices[prices["source"] == "africafertilizer"]
    assert not (afe["country_iso3"] == "ETH").any(), (
        "Ethiopia present in africafertilizer rows — VIFAA gap canary triggered"
    )


def test_use_schema(use: pd.DataFrame) -> None:
    assert tuple(use.columns) == USE_COLS


def test_use_minimum_rows(use: pd.DataFrame) -> None:
    assert len(use) > 80000, f"only {len(use)} use rows"


def test_use_faostat_has_npk(use: pd.DataFrame) -> None:
    fao = use[use["source"] == "faostat"]
    nutrients = set(fao["nutrient"].dropna().unique())
    assert {"N", "P2O5", "K2O"} <= nutrients, f"faostat missing nutrients: {nutrients}"


def test_use_faostat_product_cross_check_present(use: pd.DataFrame) -> None:
    assert "faostat_product" in set(use["source"].dropna().unique())


def test_use_india_dof_consumption_present(use: pd.DataFrame) -> None:
    assert "india_dof_consumption" in set(use["source"].dropna().unique())


def test_use_state_consumption_optional(use: pd.DataFrame) -> None:
    """india_dof_state_consumption is best-effort — may be missing if the API is down,
    but if present, state_or_region must be populated.
    """
    state_rows = use[use["source"] == "india_dof_state_consumption"]
    if len(state_rows) > 0:
        assert state_rows["state_or_region"].notna().all(), (
            "india_dof_state_consumption rows must have state_or_region populated"
        )


def test_use_tier1_countries_present(use: pd.DataFrame) -> None:
    have = set(use["country_iso3"].dropna().unique())
    need = {"IND", "NGA", "ETH", "TZA", "KEN"}
    missing = need - have
    assert not missing, f"missing tier-1 countries: {missing}"


def test_use_national_rows_have_null_state(use: pd.DataFrame) -> None:
    """National-level sources should not populate state_or_region."""
    national_sources = {"faostat", "faostat_product", "owid", "wb_wdi", "india_dof_consumption"}
    nat = use[use["source"].isin(national_sources)]
    populated = nat[nat["state_or_region"].notna()]
    assert populated.empty, (
        f"national source rows have state_or_region populated: "
        f"{populated[['source', 'state_or_region']].head(5).to_dict(orient='records')}"
    )
