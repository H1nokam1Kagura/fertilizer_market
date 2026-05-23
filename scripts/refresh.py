"""refresh.py — Pull fertilizer price + use data from public sources, emit
canonical parquet + CSV. Python port of Refresh-FertilizerMarket.ps1.

Pipeline:
    PREFLIGHT → PULL (8 sources) → NORMALIZE → EMIT → LOG

Sources (v1):
    Price — WB Pink Sheet (XLSX), AfricaFertilizer (VIFAA REST),
            data.gov.in DoF subsidy (CSV)
    Use   — FAOSTAT RFN + RFB (ZIP), OWID grapher (CSV), WB WDI (JSON),
            data.gov.in DoF consumption (derived)

This is the canonical refresh runner. The PowerShell sibling
(scripts/Refresh-FertilizerMarket.ps1) remains for ad-hoc workstation runs
that need the Databricks-push step. CI (weekly-refresh.yml on ubuntu-latest)
calls this script.

Usage:
    python scripts/refresh.py                              # emit to ./data
    python scripts/refresh.py --out-dir build/             # custom output dir
    python scripts/refresh.py --log-path build/log.csv     # custom log
    python scripts/refresh.py --skip africafertilizer      # skip one source

Requires: pandas, pyarrow, openpyxl, pycountry, requests.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import logging
import os
import re
import shutil
import sys
import tempfile
import time
import warnings
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

import pandas as pd
import requests

log = logging.getLogger("refresh")

PRICE_COLS = ['source', 'source_record_id', 'country_iso3', 'country_name', 'product',
              'product_grade', 'market_level', 'year', 'month', 'price_usd_per_t',
              'price_local_per_t', 'currency', 'source_url', 'retrieved_at', 'review_flags']
USE_COLS = ['source', 'source_record_id', 'country_iso3', 'country_name', 'state_or_region',
            'year', 'nutrient', 'total_tonnes', 'kg_per_ha_arable', 'arable_land_ha',
            'source_url', 'retrieved_at', 'review_flags']

# ── HELPERS ─────────────────────────────────────────────────────────────────

def with_retry(label: str, fn: Callable[[], Any], max_attempts: int = 3,
               backoff_sec: int = 5) -> Any:
    last: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001
            last = exc
            if attempt < max_attempts:
                log.warning("[%s] attempt %d failed: %s. retrying in %ds",
                            label, attempt, exc, backoff_sec)
                time.sleep(backoff_sec)
    assert last is not None
    raise last


# Some public endpoints (data.gov.in in particular) throttle the default
# python-requests User-Agent. Send a generic browser-shaped UA on all GET calls.
DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; fertilizer-market-canonical/1.0)",
    "Accept": "*/*",
}


def download(url: str, dest: Path, label: str, timeout: int = 180) -> None:
    def _do() -> None:
        with requests.get(url, stream=True, timeout=timeout, headers=DEFAULT_HEADERS) as resp:
            resp.raise_for_status()
            with dest.open("wb") as fh:
                for chunk in resp.iter_content(chunk_size=1 << 16):
                    if chunk:
                        fh.write(chunk)
    with_retry(label, _do)


def canonical_product(name: str) -> str:
    n = (name or "").lower().strip()
    if re.search(r"urea", n):
        return "urea"
    if re.search(r"\bdap\b|diammonium", n):
        return "dap"
    if re.search(r"\bcan\b|calcium ammonium", n):
        return "can"
    if re.search(r"\bmop\b|muriate|potassium chloride", n):
        return "mop"
    if re.search(r"\btsp\b|triple super", n):
        return "tsp"
    if "npk" in n:
        m = re.search(r"(\d+)[-\s](\d+)[-\s](\d+)", n)
        if m:
            return f"npk_{m.group(1)}_{m.group(2)}_{m.group(3)}"
        return "npk"
    return re.sub(r"[^a-z0-9]+", "_", n).strip("_")


VIFAA_ISO3_TO_ISO2 = {
    "NGA": "NG", "ETH": "ET", "KEN": "KE", "TZA": "TZ", "GHA": "GH",
    "MWI": "MW", "MOZ": "MZ", "ZMB": "ZM", "UGA": "UG", "SEN": "SN", "RWA": "RW",
}
VIFAA_GAP_COUNTRIES = {"ETH"}  # empty compoundProductsSelected upstream, see chad #4

MONTH_NUM = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], start=1)}

# ── PULL: PRICE SOURCES ─────────────────────────────────────────────────────

def get_wb_pinksheet(dest: Path) -> None:
    url = ("https://thedocs.worldbank.org/en/doc/"
           "18675f1d1639c7a34d463f59263ba0a2-0050012025/related/"
           "CMO-Historical-Data-Monthly.xlsx")
    download(url, dest, "wb-pinksheet", timeout=60)
    log.info("[PRICE] WB Pink Sheet → %s (%.2f MB)", dest, dest.stat().st_size / 1e6)


def get_africa_fertilizer(iso3_list: list[str], dest_dir: Path) -> None:
    """Pull VIFAA retail series. Two-step: GET filter defaults → POST series body.
    Body must include countryIso (ISO2), lang, dates window, and a
    currencyCode/unit pair. Falls back to /byProductsAndDates per-product if
    seriesByProducts returns empty.
    """
    base = "https://admin.africafertilizer.org"
    headers = {
        "Origin": "https://viz.africafertilizer.org",
        "Referer": "https://viz.africafertilizer.org/",
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    for iso3 in iso3_list:
        iso2 = VIFAA_ISO3_TO_ISO2.get(iso3)
        if not iso2:
            log.warning("[PRICE] AfricaFertilizer %s — not in VIFAA dataset, skipping", iso3)
            continue
        if iso3 in VIFAA_GAP_COUNTRIES:
            log.info("[PRICE] AfricaFertilizer %s — known VIFAA data gap, skipping", iso3)
            continue
        dest = dest_dir / f"afe_{iso3}.csv"
        try:
            with_retry(f"afe-{iso3}", lambda iso2=iso2, iso3=iso3, dest=dest: _pull_afe_series(
                base, headers, iso2, iso3, dest))
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            if "empty serieByMonth" in msg or "no compoundProductsSelected" in msg:
                try:
                    log.info("[PRICE] AfricaFertilizer %s — primary endpoint empty, trying byProductsAndDates fallback", iso3)
                    _pull_afe_fallback(base, headers, iso2, iso3, dest)
                except Exception as inner:  # noqa: BLE001
                    log.warning("[PRICE] AfricaFertilizer %s fallback failed: %s", iso3, inner)
            else:
                log.warning("[PRICE] AfricaFertilizer %s failed: %s — skipping", iso3, msg)
        time.sleep(2)


def _pull_afe_series(base: str, headers: dict, iso2: str, iso3: str, dest: Path) -> None:
    defs_url = f"{base}/api/filtersDefaults/prices/seriesByProducts?countryIso={iso2}&selectedLanguage=en"
    defs = requests.get(defs_url, headers=headers, timeout=60).json()
    products = defs.get("compoundProductsSelected") or []
    if not products:
        raise RuntimeError(f"no compoundProductsSelected in filter defaults for {iso2}")
    local_currency = defs.get("currencyCode")
    local_unit = defs.get("unit")
    body = dict(defs)
    body["countryIso"] = iso2
    body["lang"] = "en"
    body["dates"] = ["2010-01-01", "2025-12-31"]

    def _post(cc: str, unit: str) -> Any:
        body["currencyCode"] = cc
        body["unit"] = unit
        r = requests.post(f"{base}/api/prices/seriesByProducts",
                          headers=headers, json=body, timeout=180)
        r.raise_for_status()
        return r.json()

    usd_resp = _post("USD", "USD_MT")
    loc_resp = _post(local_currency, local_unit) if local_currency else None

    def _series(resp: Any) -> list[dict]:
        if isinstance(resp, list) and resp:
            return resp[0].get("serieByMonth", [])
        if isinstance(resp, dict):
            return resp.get("serieByMonth", [])
        return []

    usd_series = _series(usd_resp)
    loc_series = _series(loc_resp) if loc_resp is not None else []
    if not usd_series:
        raise RuntimeError("empty serieByMonth in USD response")

    loc_map: dict[str, dict[str, float]] = {}
    for s in loc_series:
        key = f"{s.get('seriesInfo', {}).get('hsCode')}|{s.get('id')}" if s.get("seriesInfo", {}).get("hsCode") else s.get("id")
        if not key:
            continue
        loc_map[key] = {d.get("x"): d.get("y") for d in s.get("data", []) if d.get("y") is not None}

    rows: list[dict] = []
    for s in usd_series:
        hs = s.get("seriesInfo", {}).get("hsCode")
        sid = s.get("id")
        key = f"{hs}|{sid}" if hs else sid
        prod = canonical_product(sid or "")
        for d in s.get("data", []):
            y = d.get("y")
            x = d.get("x", "")
            if y is None or not x or "-" not in x:
                continue
            parts = x.split("-")
            if len(parts) != 2 or parts[0] not in MONTH_NUM:
                continue
            try:
                year_i = int(parts[1])
            except ValueError:
                continue
            loc_t = loc_map.get(key, {}).get(x)
            rows.append({
                "product": prod, "product_name_raw": sid, "hs_code": hs,
                "year": year_i, "month": MONTH_NUM[parts[0]],
                "price_usd_per_t": y, "price_local_per_t": loc_t,
                "currency": local_currency, "market_level": "retail",
            })
    if not rows:
        raise RuntimeError(f"no rows extracted from {iso2} series response")
    pd.DataFrame(rows).to_csv(dest, index=False, encoding="utf-8")
    log.info("[PRICE] AfricaFertilizer %s (%s) → %s (%d rows, %d products)",
             iso3, iso2, dest, len(rows), len({r['product'] for r in rows}))


def _pull_afe_fallback(base: str, headers: dict, iso2: str, iso3: str, dest: Path) -> None:
    defs_url = f"{base}/api/filtersDefaults/prices/byProducts?countryIso={iso2}&selectedLanguage=en"
    defs = requests.get(defs_url, headers=headers, timeout=60).json()
    products = defs.get("compoundProductsSelected") or []
    rows: list[dict] = []
    for prod_name in products:
        body = dict(defs)
        body["countryIso"] = iso2
        body["lang"] = "en"
        body["dates"] = ["2010-01-01", "2025-12-31"]
        body["compoundProductSelected"] = prod_name
        body.pop("compoundProductsSelected", None)
        body["currencyCode"] = "USD"
        body["unit"] = "USD_MT"
        try:
            r = requests.post(f"{base}/api/prices/byProductsAndDates",
                              headers=headers, json=body, timeout=120)
            r.raise_for_status()
            resp = r.json()
        except Exception as exc:  # noqa: BLE001
            log.warning("  byProductsAndDates %s/%s failed: %s", iso3, prod_name, exc)
            continue
        if isinstance(resp, list) and resp and "data" in resp[0]:
            data = resp[0]["data"]
        elif isinstance(resp, dict) and "data" in resp:
            data = resp["data"]
        elif isinstance(resp, list):
            data = resp
        else:
            data = []
        prod = canonical_product(prod_name)
        for d in data:
            y = d.get("y") if isinstance(d, dict) else None
            x = d.get("x") or d.get("date") if isinstance(d, dict) else None
            if y is None or not x or "-" not in x:
                continue
            parts = x.split("-")
            if len(parts) != 2 or parts[0] not in MONTH_NUM:
                continue
            try:
                year_i = int(parts[1])
            except ValueError:
                continue
            rows.append({
                "product": prod, "product_name_raw": prod_name, "hs_code": None,
                "year": year_i, "month": MONTH_NUM[parts[0]],
                "price_usd_per_t": y, "price_local_per_t": None,
                "currency": "USD", "market_level": "retail",
            })
        time.sleep(0.5)
    if rows:
        pd.DataFrame(rows).to_csv(dest, index=False, encoding="utf-8")
        log.info("[PRICE] AfricaFertilizer %s (%s) fallback → %s (%d rows, %d products)",
                 iso3, iso2, dest, len(rows), len({r['product'] for r in rows}))
    else:
        log.warning("[PRICE] AfricaFertilizer %s fallback produced 0 rows", iso3)


# ── PULL: USE SOURCES ───────────────────────────────────────────────────────

def get_faostat_nutrient(dest: Path) -> None:
    url = ("https://fenixservices.fao.org/faostat/static/bulkdownloads/"
           "Inputs_FertilizersNutrient_E_All_Data_(Normalized).zip")
    download(url, dest, "faostat-zip", timeout=180)
    log.info("[USE] FAOSTAT Nutrient ZIP → %s (%.2f MB)", dest, dest.stat().st_size / 1e6)


def get_faostat_product(dest: Path) -> None:
    url = ("https://fenixservices.fao.org/faostat/static/bulkdownloads/"
           "Inputs_FertilizersProduct_E_All_Data_(Normalized).zip")
    download(url, dest, "faostat-product-zip", timeout=180)
    log.info("[USE] FAOSTAT Product ZIP → %s (%.2f MB)", dest, dest.stat().st_size / 1e6)


def get_owid(dest: Path) -> None:
    url = "https://ourworldindata.org/grapher/fertilizer-use-in-kg-per-hectare-of-arable-land.csv"
    download(url, dest, "owid-fert", timeout=60)
    log.info("[USE] OWID → %s", dest)


def get_wb_wdi(dest: Path) -> None:
    url = ("https://api.worldbank.org/v2/country/all/indicator/AG.CON.FERT.ZS"
           "?format=json&per_page=20000")
    download(url, dest, "wb-wdi", timeout=90)
    log.info("[USE] WB WDI → %s", dest)


DATAGOVIN_KEY_DEFAULT = "579b464db66ec23bdd000001cdd3946e44ce4aad7209ff7b23ac571b"


def _fetch_datagovin(uuid: str, dest_csv: Path, label: str, page_size: int = 100) -> int:
    """Paginate data.gov.in resource into a single CSV. The public guest API key
    silently caps each call at 10 records regardless of the requested limit; first
    call probes `total` and subsequent calls iterate `offset`. Returns the row count.
    """
    key = os.environ.get("DATAGOVIN_API_KEY", DATAGOVIN_KEY_DEFAULT)
    base_url = f"https://api.data.gov.in/resource/{uuid}"
    all_records: list[dict] = []
    field_meta: list[dict] = []
    offset = 0
    total = None
    while True:
        url = f"{base_url}?api-key={key}&format=json&limit={page_size}&offset={offset}"
        def _fetch_page(u=url):
            r = requests.get(u, headers=DEFAULT_HEADERS, timeout=60)
            r.raise_for_status()
            return r.json()
        page = with_retry(label, _fetch_page)
        if "error" in page:
            raise RuntimeError(f"data.gov.in {label}: {page['error']}")
        if not field_meta:
            field_meta = page.get("field", [])
        records = page.get("records", [])
        if not records:
            break
        all_records.extend(records)
        if total is None:
            total = page.get("total")
        if total is not None and len(all_records) >= total:
            break
        if len(records) < page_size:
            # Server returned fewer than requested — likely guest-key 10-row cap.
            # If we got 10 and total is known, keep going; else stop.
            if total is None or len(all_records) >= total:
                break
        offset += len(records)
        if offset > 10_000:  # sanity guard
            break
    # Write a CSV. Use the field metadata's `id` column as the header so the
    # download-vs-API field name shapes stay consistent.
    field_ids = [f.get("id") for f in field_meta if f.get("id")]
    # Records use the id as the key. Fall back to first record's keys if metadata empty.
    if not field_ids and all_records:
        field_ids = list(all_records[0].keys())
    dest_csv.parent.mkdir(parents=True, exist_ok=True)
    with dest_csv.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=field_ids, extrasaction="ignore")
        writer.writeheader()
        for rec in all_records:
            writer.writerow(rec)
    return len(all_records)


def get_datagovin_dof(dest_dir: Path) -> None:
    """India Department of Fertilizers via data.gov.in REST. Public guest key
    works without signup. CKAN /api/3/action paths return 500 — use the direct
    /resource/<UUID> endpoint with offset-pagination (guest key caps at 10/call).
    """
    resources = {
        "subsidy":     "2e0e6c04-97f2-456b-9309-bf605650cb11",
        "consumption": "755bdf8b-956e-418c-9835-3ca4fd5b1b43",
    }
    for name, uuid in resources.items():
        dest = dest_dir / f"india_dof_{name}.csv"
        try:
            row_count = _fetch_datagovin(uuid, dest, f"datagovin-{name}")
            log.info("[INDIA-DOF] %s → %s (%d rows)", name, dest, row_count)
        except Exception as exc:  # noqa: BLE001
            log.warning("[INDIA-DOF] %s failed: %s", name, exc)


def get_datagovin_state_consumption(dest: Path) -> None:
    """State/UT-wise demand/supply/consumption of Urea/DAP/MOP/NPKS 2019-20 to 2023-24
    (resource c7c7d147-5635-445c-ae05-cb3dfb68e3c0). 37 states × 5 years × 4 products
    × 3 metrics. Discovered 2026-05-23 via data.gov.in catalog.
    """
    row_count = _fetch_datagovin(
        "c7c7d147-5635-445c-ae05-cb3dfb68e3c0", dest, "datagovin-state-consumption")
    log.info("[INDIA-DOF-STATE] consumption → %s (%d rows)", dest, row_count)


def get_datagovin_district_npk(dest: Path) -> None:
    """District × Nutrient (N/P/K/Total) chemical fertilizer distributed in tonnes,
    2019-20 (resource 93051de3-ccea-45b1-8026-5836ae176b10). 30 districts. Discovered
    2026-05-23. The only data.gov.in source with direct N/P/K (no derivation).
    """
    row_count = _fetch_datagovin(
        "93051de3-ccea-45b1-8026-5836ae176b10", dest, "datagovin-district-npk")
    log.info("[INDIA-DOF-DISTRICT] npk → %s (%d rows)", dest, row_count)


# ── NORMALIZE ───────────────────────────────────────────────────────────────

def empty_frame(cols: list[str]) -> pd.DataFrame:
    return pd.DataFrame({c: pd.Series(dtype="object") for c in cols})


def normalize(staging: Path, results: dict[str, str], retrieved_at: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    import pycountry

    prices = empty_frame(PRICE_COLS)
    use = empty_frame(USE_COLS)

    # ── WB Pink Sheet (monthly XLSX) ────────────────────────────────────────
    if results.get("wb_pinksheet") == "ok":
        src_url = "https://thedocs.worldbank.org/.../CMO-Historical-Data-Monthly.xlsx"
        xlsx = staging / "pinksheet.xlsx"
        try:
            xls = pd.ExcelFile(xlsx, engine="openpyxl")
            sheet = next((s for s in xls.sheet_names if re.match(r"^Monthly Prices", s, re.I)), None)
            if not sheet:
                sheet = next((s for s in xls.sheet_names if re.match(r"^Monthly", s, re.I)), None)
            if not sheet:
                raise RuntimeError(f"no Monthly sheet in {xls.sheet_names}")
            df = pd.read_excel(xlsx, sheet_name=sheet, engine="openpyxl", header=4)
            df = df.rename(columns={df.columns[0]: "date_raw"})

            def parse_d(s: Any) -> tuple[Any, Any]:
                m = re.match(r"^(\d{4})M(\d{1,2})$", str(s).strip())
                if m:
                    return int(m.group(1)), int(m.group(2))
                m = re.match(r"^(\d{4})-(\d{1,2})", str(s).strip())
                if m:
                    return int(m.group(1)), int(m.group(2))
                return None, None

            df[["year", "month"]] = df["date_raw"].apply(lambda s: pd.Series(parse_d(s)))
            df = df.dropna(subset=["year", "month"])
            wanted = {
                "Urea, (Ukraine), f.o.b.": ("urea", "global_fob", "prilled"),
                "Urea": ("urea", "global_fob", "prilled"),
                "DAP": ("dap", "global_fob", "granular"),
                "Phosphate rock": ("phosphate_rock", "global_fob", "bulk"),
                "TSP": ("tsp", "global_fob", "granular"),
                "Potassium chloride": ("mop", "global_fob", "granular"),
                "Potassium chloride (Muriate of Potash)": ("mop", "global_fob", "granular"),
            }
            ps_rows: list[dict] = []
            for col, (prod, level, grade) in wanted.items():
                if col not in df.columns:
                    cand = [c for c in df.columns
                            if isinstance(c, str) and col.lower().split(",")[0].strip() in c.lower()]
                    if not cand:
                        continue
                    col = cand[0]
                sub = df[["year", "month", col]].copy()
                sub[col] = pd.to_numeric(sub[col], errors="coerce")
                sub = sub.dropna()
                for rec in sub.itertuples(index=False):
                    y, m, v = rec
                    ps_rows.append({
                        "source": "wb_pinksheet",
                        "source_record_id": f"wb_pinksheet|{prod}|GLB|{int(y)}-{int(m):02d}",
                        "country_iso3": None, "country_name": None,
                        "product": prod, "product_grade": grade, "market_level": level,
                        "year": int(y), "month": int(m),
                        "price_usd_per_t": float(v),
                        "price_local_per_t": None, "currency": "USD",
                        "source_url": src_url, "retrieved_at": retrieved_at,
                        "review_flags": "",
                    })
            if ps_rows:
                prices = pd.concat([prices, pd.DataFrame(ps_rows, columns=PRICE_COLS)], ignore_index=True)
            log.info("wb_pinksheet rows: %d", len(ps_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("wb_pinksheet parse failed: %s", exc)

    # ── AfricaFertilizer per-country CSVs ──────────────────────────────────
    if results.get("africafertilizer") == "ok":
        src_url = "https://admin.africafertilizer.org/api/prices/seriesByProducts"
        afe_dir = staging / "afe"
        afe_rows: list[dict] = []
        if afe_dir.exists():
            for csv_path in sorted(afe_dir.glob("afe_*.csv")):
                iso = csv_path.stem.split("_", 1)[1]
                try:
                    df = pd.read_csv(csv_path)
                    cols_lower = {c.lower(): c for c in df.columns}

                    def pick(*names: str) -> str | None:
                        for n in names:
                            if n in cols_lower:
                                return cols_lower[n]
                        return None

                    col_prod = pick("product", "fertilizer", "commodity")
                    col_year = pick("year")
                    col_month = pick("month")
                    col_date = pick("date", "period")
                    col_usd = pick("price_usd", "usd", "price_usd_per_t", "price (usd/mt)")
                    col_loc = pick("price_local", "local", "price_local_per_t")
                    col_curr = pick("currency", "ccy")
                    col_lvl = pick("market_level", "level")
                    for _, r in df.iterrows():
                        y, m = None, None
                        if col_year and col_month:
                            try:
                                y, m = int(r[col_year]), int(r[col_month])
                            except Exception:  # noqa: BLE001
                                y, m = None, None
                        elif col_date:
                            try:
                                dt = pd.to_datetime(r[col_date], errors="coerce")
                                if pd.notna(dt):
                                    y, m = dt.year, dt.month
                            except Exception:  # noqa: BLE001
                                pass
                        if y is None or m is None:
                            continue
                        prod_raw = str(r[col_prod]).strip().lower() if col_prod else "urea"
                        prod = {
                            "urea": "urea", "dap": "dap", "npk": "npk_15_15_15",
                            "potash": "mop", "mop": "mop", "tsp": "tsp",
                        }.get(prod_raw, re.sub(r"[^a-z0-9_]+", "_", prod_raw))
                        afe_rows.append({
                            "source": "africafertilizer",
                            "source_record_id": f"afe|{prod}|{iso}|{y}-{m:02d}",
                            "country_iso3": iso, "country_name": None,
                            "product": prod, "product_grade": None,
                            "market_level": str(r[col_lvl]).lower() if col_lvl else "retail",
                            "year": y, "month": m,
                            "price_usd_per_t": float(r[col_usd]) if col_usd and pd.notna(r[col_usd]) else None,
                            "price_local_per_t": float(r[col_loc]) if col_loc and pd.notna(r[col_loc]) else None,
                            "currency": str(r[col_curr]) if col_curr and pd.notna(r[col_curr]) else None,
                            "source_url": src_url, "retrieved_at": retrieved_at, "review_flags": "",
                        })
                except Exception as exc:  # noqa: BLE001
                    log.warning("afe %s parse failed: %s", iso, exc)
        if afe_rows:
            prices = pd.concat([prices, pd.DataFrame(afe_rows, columns=PRICE_COLS)], ignore_index=True)
        log.info("africafertilizer rows: %d", len(afe_rows))

    # ── FAOSTAT RFN (Fertilizers by Nutrient, Normalized) ──────────────────
    # ItemCodes.csv metadata file lists only 3102 (N), but the data CSV
    # contains 3103 (P2O5) and 3104 (K2O) too. Don't trust the metadata.
    if results.get("faostat") == "ok":
        src_url = ("https://fenixservices.fao.org/faostat/static/bulkdownloads/"
                   "Inputs_FertilizersNutrient_E_All_Data_(Normalized).zip")
        z = staging / "faostat.zip"
        try:
            with zipfile.ZipFile(z) as zf:
                csv_name = next((n for n in zf.namelist()
                                 if n.lower().endswith(".csv") and "all_data" in n.lower()), None)
                if not csv_name:
                    csv_name = next(n for n in zf.namelist() if n.lower().endswith(".csv"))
                with zf.open(csv_name) as fh:
                    raw = fh.read()
            try:
                txt = raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                txt = raw.decode("latin-1")
            df = pd.read_csv(io.StringIO(txt), low_memory=False)
            item_map = {3102: "N", 3103: "P2O5", 3104: "K2O"}
            element_to_field = {5157: "total_tonnes", 5159: "kg_per_ha_arable"}
            df = df[df["Item Code"].isin(item_map) & df["Element Code"].isin(element_to_field)]

            m49_cache: dict[str, str | None] = {}

            def m49_to_iso3(m49_str: Any) -> str | None:
                key = str(m49_str).lstrip("'").strip().zfill(3)
                if key in m49_cache:
                    return m49_cache[key]
                try:
                    obj = pycountry.countries.get(numeric=key)
                    iso = obj.alpha_3 if obj else None
                except Exception:  # noqa: BLE001
                    iso = None
                m49_cache[key] = iso
                return iso

            df = df.dropna(subset=["Value", "Year", "Area Code (M49)", "Item Code", "Element Code"])
            df["iso3"] = df["Area Code (M49)"].map(m49_to_iso3)
            df = df.dropna(subset=["iso3"])
            df["year_i"] = df["Year"].astype(int)
            df["nutrient"] = df["Item Code"].astype(int).map(item_map)
            df["field"] = df["Element Code"].astype(int).map(element_to_field)
            df["val_f"] = df["Value"].astype(float)
            df["elt_code"] = df["Element Code"].astype(int)
            new_rows: list[dict] = []
            for rec in df[["iso3", "Area", "year_i", "nutrient", "field", "val_f", "elt_code"]].itertuples(index=False):
                row = {
                    "source": "faostat",
                    "source_record_id": f"faostat|{rec.iso3}|{rec.nutrient}|{rec.year_i}|{rec.elt_code}",
                    "country_iso3": rec.iso3,
                    "country_name": rec.Area,
                    "state_or_region": None,
                    "year": rec.year_i,
                    "nutrient": rec.nutrient,
                    "total_tonnes": None,
                    "kg_per_ha_arable": None,
                    "arable_land_ha": None,
                    "source_url": src_url,
                    "retrieved_at": retrieved_at,
                    "review_flags": "",
                }
                row[rec.field] = rec.val_f
                new_rows.append(row)
            if new_rows:
                use = pd.concat([use, pd.DataFrame(new_rows, columns=USE_COLS)], ignore_index=True)
            log.info("faostat rows: %d", len(new_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("faostat parse failed: %s", exc)

    # ── FAOSTAT FertilizersProduct → derive P2O5 + K2O cross-check ─────────
    if results.get("faostat_product") == "ok":
        src_url = ("https://fenixservices.fao.org/faostat/static/bulkdownloads/"
                   "Inputs_FertilizersProduct_E_All_Data_(Normalized).zip")
        z = staging / "faostat_product.zip"
        try:
            with zipfile.ZipFile(z) as zf:
                csv_name = next((n for n in zf.namelist()
                                 if n.lower().endswith(".csv") and "all_data" in n.lower()), None)
                if not csv_name:
                    csv_name = next(n for n in zf.namelist() if n.lower().endswith(".csv"))
                with zf.open(csv_name) as fh:
                    raw = fh.read()
            try:
                txt = raw.decode("utf-8-sig")
            except UnicodeDecodeError:
                txt = raw.decode("latin-1")
            df = pd.read_csv(io.StringIO(txt), low_memory=False)
            # Stable-composition products → (P2O5_pct, K2O_pct). N omitted —
            # RFN block above is more accurate.
            product_pk = {
                4011: (33.0, 0.0), 4012: (46.0, 0.0), 4013: (16.0, 0.0),
                4016: (0.0, 60.0), 4017: (0.0, 50.0),
                4022: (46.0, 0.0), 4023: (52.0, 0.0),
                4025: (0.0, 44.0), 4027: (30.0, 30.0),
            }
            df = df[df["Item Code"].isin(product_pk) & (df["Element Code"].astype(int) == 5157)]

            m49_cache_p: dict[str, str | None] = {}

            def m49_to_iso3_p(m49_str: Any) -> str | None:
                key = str(m49_str).lstrip("'").strip().zfill(3)
                if key in m49_cache_p:
                    return m49_cache_p[key]
                try:
                    obj = pycountry.countries.get(numeric=key)
                    iso = obj.alpha_3 if obj else None
                except Exception:  # noqa: BLE001
                    iso = None
                m49_cache_p[key] = iso
                return iso

            df = df.dropna(subset=["Value", "Year", "Area Code (M49)", "Item Code"])
            df["iso3"] = df["Area Code (M49)"].map(m49_to_iso3_p)
            df = df.dropna(subset=["iso3"])
            df["year_i"] = df["Year"].astype(int)
            df["item_code"] = df["Item Code"].astype(int)
            df["tonnes"] = df["Value"].astype(float)
            agg = df.groupby(["iso3", "Area", "year_i", "item_code"], as_index=False)["tonnes"].sum()
            prod_rows: list[dict] = []
            for rec in agg.itertuples(index=False):
                p2o5_pct, k2o_pct = product_pk[rec.item_code]
                if p2o5_pct > 0:
                    prod_rows.append({
                        "source": "faostat_product",
                        "source_record_id": f"faostat_product|{rec.iso3}|P2O5|{rec.year_i}|{rec.item_code}",
                        "country_iso3": rec.iso3, "country_name": rec.Area,
                        "state_or_region": None,
                        "year": rec.year_i, "nutrient": "P2O5",
                        "total_tonnes": rec.tonnes * (p2o5_pct / 100.0),
                        "kg_per_ha_arable": None, "arable_land_ha": None,
                        "source_url": src_url, "retrieved_at": retrieved_at,
                        "review_flags": f"derived_from_item_{rec.item_code}",
                    })
                if k2o_pct > 0:
                    prod_rows.append({
                        "source": "faostat_product",
                        "source_record_id": f"faostat_product|{rec.iso3}|K2O|{rec.year_i}|{rec.item_code}",
                        "country_iso3": rec.iso3, "country_name": rec.Area,
                        "state_or_region": None,
                        "year": rec.year_i, "nutrient": "K2O",
                        "total_tonnes": rec.tonnes * (k2o_pct / 100.0),
                        "kg_per_ha_arable": None, "arable_land_ha": None,
                        "source_url": src_url, "retrieved_at": retrieved_at,
                        "review_flags": f"derived_from_item_{rec.item_code}",
                    })
            if prod_rows:
                pdf = pd.DataFrame(prod_rows, columns=USE_COLS)
                rollup = (pdf.groupby(["country_iso3", "country_name", "year", "nutrient"], as_index=False)
                          .agg({"total_tonnes": "sum",
                                "review_flags": lambda s: "derived_from_items:" + ",".join(sorted(set(
                                    ",".join(s).replace("derived_from_item_", "").split(","))))}))
                rollup["source"] = "faostat_product"
                rollup["source_record_id"] = (rollup["source"] + "|" + rollup["country_iso3"] + "|" +
                                              rollup["nutrient"] + "|" + rollup["year"].astype(str))
                rollup["state_or_region"] = None
                rollup["kg_per_ha_arable"] = None
                rollup["arable_land_ha"] = None
                rollup["source_url"] = src_url
                rollup["retrieved_at"] = retrieved_at
                rollup = rollup[USE_COLS]
                use = pd.concat([use, rollup], ignore_index=True)
                log.info("faostat_product rows: %d (from %d product-nutrient pairs)", len(rollup), len(prod_rows))
            else:
                log.info("faostat_product rows: 0")
        except Exception as exc:  # noqa: BLE001
            log.warning("faostat_product parse failed: %s", exc)

    # ── OWID ────────────────────────────────────────────────────────────────
    if results.get("owid") == "ok":
        src_url = "https://ourworldindata.org/grapher/fertilizer-use-in-kg-per-hectare-of-arable-land.csv"
        try:
            df = pd.read_csv(staging / "owid.csv")
            val_col = next((c for c in df.columns
                            if c not in ("Entity", "Code", "Year") and df[c].dtype.kind in "fi"), None)
            owid_rows: list[dict] = []
            if val_col:
                sub = df.dropna(subset=["Code", "Year", val_col]).copy()
                sub["year_i"] = sub["Year"].astype(int)
                sub["val_f"] = sub[val_col].astype(float)
                sub["Code"] = sub["Code"].astype(str)
                for rec in sub[["Code", "Entity", "year_i", "val_f"]].itertuples(index=False):
                    owid_rows.append({
                        "source": "owid",
                        "source_record_id": f"owid|{rec.Code}|total|{rec.year_i}",
                        "country_iso3": rec.Code, "country_name": rec.Entity,
                        "state_or_region": None,
                        "year": rec.year_i, "nutrient": "total",
                        "total_tonnes": None, "kg_per_ha_arable": rec.val_f,
                        "arable_land_ha": None,
                        "source_url": src_url, "retrieved_at": retrieved_at, "review_flags": "",
                    })
            if owid_rows:
                use = pd.concat([use, pd.DataFrame(owid_rows, columns=USE_COLS)], ignore_index=True)
            log.info("owid rows: %d", len(owid_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("owid parse failed: %s", exc)

    # ── WB WDI ──────────────────────────────────────────────────────────────
    if results.get("wb_wdi") == "ok":
        src_url = "https://api.worldbank.org/v2/country/all/indicator/AG.CON.FERT.ZS"
        try:
            blob = json.loads((staging / "wb_wdi.json").read_text(encoding="utf-8"))
            rows_raw = blob[1] if isinstance(blob, list) and len(blob) > 1 else []
            wdi_rows: list[dict] = []
            for r in rows_raw:
                iso3 = (r.get("countryiso3code") or "").strip()
                if not iso3 or not re.match(r"^[A-Z]{3}$", iso3):
                    continue
                val = r.get("value")
                yr = r.get("date")
                if val is None:
                    continue
                try:
                    year_i = int(yr)
                except Exception:  # noqa: BLE001
                    continue
                wdi_rows.append({
                    "source": "wb_wdi",
                    "source_record_id": f"wb_wdi|{iso3}|total|{year_i}",
                    "country_iso3": iso3, "country_name": (r.get("country") or {}).get("value"),
                    "state_or_region": None,
                    "year": year_i, "nutrient": "total",
                    "total_tonnes": None, "kg_per_ha_arable": float(val),
                    "arable_land_ha": None,
                    "source_url": src_url, "retrieved_at": retrieved_at, "review_flags": "",
                })
            if wdi_rows:
                use = pd.concat([use, pd.DataFrame(wdi_rows, columns=USE_COLS)], ignore_index=True)
            log.info("wb_wdi rows: %d", len(wdi_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("wb_wdi parse failed: %s", exc)

    # ── India DOF (data.gov.in) ─────────────────────────────────────────────
    if results.get("india_dof") == "ok":
        src_subsidy = "https://api.data.gov.in/resource/2e0e6c04-97f2-456b-9309-bf605650cb11"
        src_cons = "https://api.data.gov.in/resource/755bdf8b-956e-418c-9835-3ca4fd5b1b43"
        idof_dir = staging / "india_dof"

        # (a) Annual subsidy → fertilizer_price (market_level=subsidy_total_inr_crores, month=12)
        try:
            subsidy_csv = idof_dir / "india_dof_subsidy.csv"
            if subsidy_csv.exists():
                df = pd.read_csv(subsidy_csv)

                def norm_col(c: str) -> str:
                    return re.sub(r"[^a-z0-9]+", "_", c.lower()).strip("_")

                df.columns = [norm_col(c) for c in df.columns]

                def pickc(*needles: str) -> str | None:
                    for needle in needles:
                        needle_n = norm_col(needle)
                        for c in df.columns:
                            if needle_n in c:
                                return c
                    return None

                cyear = pickc("year")
                cprod = pickc("product", "particulars", "item")
                cval = pickc("subsidy", "rs_crores", "crores")
                sub_rows: list[dict] = []
                if cyear and cprod and cval:
                    for _, r in df.iterrows():
                        yraw = str(r.get(cyear, "")).strip()
                        if not yraw or yraw.lower() == "nan":
                            continue
                        ymatch = re.match(r"(\d{4})", yraw)
                        if not ymatch:
                            continue
                        yr = int(ymatch.group(1))
                        prod_raw = str(r.get(cprod, "")).strip().lower()
                        if "indigenous" in prod_raw and "urea" in prod_raw:
                            prod = "urea_indigenous"
                        elif "imported" in prod_raw and "urea" in prod_raw:
                            prod = "urea_imported"
                        elif "indigenous" in prod_raw and ("p&k" in prod_raw or "p & k" in prod_raw):
                            prod = "pk_indigenous"
                        elif "imported" in prod_raw and ("p&k" in prod_raw or "p & k" in prod_raw):
                            prod = "pk_imported"
                        else:
                            prod = re.sub(r"[^a-z0-9_]+", "_", prod_raw)
                        try:
                            v = float(r.get(cval))
                        except Exception:  # noqa: BLE001
                            continue
                        if pd.isna(v):
                            continue
                        sub_rows.append({
                            "source": "india_dof_subsidy",
                            "source_record_id": f"india_dof_subsidy|{prod}|IND|{yr}",
                            "country_iso3": "IND", "country_name": "India",
                            "product": prod, "product_grade": None,
                            "market_level": "subsidy_total_inr_crores",
                            "year": yr, "month": 12,
                            "price_usd_per_t": None, "price_local_per_t": v,
                            "currency": "INR_crores_total",
                            "source_url": src_subsidy, "retrieved_at": retrieved_at,
                            "review_flags": "annual_subsidy_total_not_per_ton",
                        })
                if sub_rows:
                    prices = pd.concat([prices, pd.DataFrame(sub_rows, columns=PRICE_COLS)], ignore_index=True)
                log.info("india_dof_subsidy rows: %d", len(sub_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("india_dof subsidy parse failed: %s", exc)

        # (b) Annual all-India consumption → fertilizer_use (derived N/P2O5/K2O)
        try:
            cons_csv = idof_dir / "india_dof_consumption.csv"
            if cons_csv.exists():
                df = pd.read_csv(cons_csv)

                def norm_col2(c: str) -> str:
                    return re.sub(r"[^a-z0-9]+", "_", c.lower()).strip("_")

                df.columns = [norm_col2(c) for c in df.columns]
                year_col = next((c for c in df.columns if "year" in c), None)
                prod_to_pct = {
                    "urea": {"N": 46.0},
                    "dap": {"N": 18.0, "P2O5": 46.0},
                    "mop": {"K2O": 60.0},
                }
                cons_rows: list[dict] = []
                if year_col:
                    for _, r in df.iterrows():
                        yraw = str(r.get(year_col, "")).strip()
                        if not yraw or yraw.lower() == "nan":
                            continue
                        ymatch = re.match(r"(\d{4})", yraw)
                        if not ymatch:
                            continue
                        yr = int(ymatch.group(1))
                        for prod_key, nutmap in prod_to_pct.items():
                            match_col = next((c for c in df.columns if prod_key in c), None)
                            if not match_col:
                                continue
                            try:
                                lakh_mt = float(r.get(match_col))
                            except Exception:  # noqa: BLE001
                                continue
                            if pd.isna(lakh_mt) or lakh_mt == 0:
                                continue
                            tonnes = lakh_mt * 100_000.0
                            for nutrient, pct in nutmap.items():
                                cons_rows.append({
                                    "source": "india_dof_consumption",
                                    "source_record_id": f"india_dof_consumption|IND|{nutrient}|{yr}|{prod_key}",
                                    "country_iso3": "IND", "country_name": "India",
                                    "state_or_region": None,
                                    "year": yr, "nutrient": nutrient,
                                    "total_tonnes": tonnes * (pct / 100.0),
                                    "kg_per_ha_arable": None, "arable_land_ha": None,
                                    "source_url": src_cons, "retrieved_at": retrieved_at,
                                    "review_flags": f"derived_from_product_{prod_key}",
                                })
                if cons_rows:
                    cdf = pd.DataFrame(cons_rows, columns=USE_COLS)
                    rollup = (cdf.groupby(["country_iso3", "country_name", "year", "nutrient"], as_index=False)
                              .agg({"total_tonnes": "sum",
                                    "review_flags": lambda s: "derived_from_products:" + ",".join(sorted(set(
                                        ",".join(s).replace("derived_from_product_", "").split(","))))}))
                    rollup["source"] = "india_dof_consumption"
                    rollup["source_record_id"] = (rollup["source"] + "|IND|" + rollup["nutrient"] + "|"
                                                  + rollup["year"].astype(str))
                    rollup["state_or_region"] = None
                    rollup["kg_per_ha_arable"] = None
                    rollup["arable_land_ha"] = None
                    rollup["source_url"] = src_cons
                    rollup["retrieved_at"] = retrieved_at
                    rollup = rollup[USE_COLS]
                    use = pd.concat([use, rollup], ignore_index=True)
                    log.info("india_dof_consumption rows: %d (from %d product-nutrient pairs)",
                             len(rollup), len(cons_rows))
                else:
                    log.info("india_dof_consumption rows: 0")
        except Exception as exc:  # noqa: BLE001
            log.warning("india_dof consumption parse failed: %s", exc)

    # ── India DOF state-year consumption (data.gov.in resource c7c7d14...) ──
    # Wide-format CSV: 37 states × {Urea, DAP, MOP, NPKS} × {DEMAND, SUPPLY, CONSUMPTION}
    # × 5 years (2019-20 to 2023-24). Only CONSUMPTION is actuals; DEMAND/SUPPLY are
    # projections. We derive N/P2O5/K2O via the same stoichiometry as india_dof_consumption.
    if results.get("india_dof_state_consumption") == "ok":
        src_url = "https://api.data.gov.in/resource/c7c7d147-5635-445c-ae05-cb3dfb68e3c0"
        csv_path = staging / "india_dof" / "state_consumption.csv"
        try:
            df = pd.read_csv(csv_path)

            def norm_col(c: str) -> str:
                return re.sub(r"[^a-z0-9]+", "_", c.lower()).strip("_")

            df.columns = [norm_col(c) for c in df.columns]
            state_col = next((c for c in df.columns if c in ("state_ut", "state", "stateut")), None)
            if not state_col:
                raise RuntimeError(f"no state column in {list(df.columns)[:5]}...")

            prod_to_pct = {
                "urea": {"N": 46.0},
                "dap":  {"N": 18.0, "P2O5": 46.0},
                "mop":  {"K2O": 60.0},
                # npks: variable composition — skip
            }
            consumption_rows: list[dict] = []
            for _, row in df.iterrows():
                state = str(row.get(state_col, "")).strip()
                if not state or state.lower() in ("nan", "total"):
                    continue
                for col in df.columns:
                    if not col.endswith("_consumption"):
                        continue
                    # After norm_col, column shape is: YYYY_YY_PRODUCT_consumption
                    # (the API field id has triple underscores but our [^a-z0-9]+→_
                    # normalization collapses them). Match relaxed.
                    m = re.match(r"^_*(\d{4})_(\d{2})_+([a-z]+)_+consumption$", col)
                    if not m:
                        continue
                    yr = int(m.group(1))
                    prod_key = m.group(3)
                    nutmap = prod_to_pct.get(prod_key)
                    if not nutmap:
                        continue
                    try:
                        lakh_mt = float(row.get(col))
                    except (TypeError, ValueError):
                        continue
                    if pd.isna(lakh_mt) or lakh_mt == 0:
                        continue
                    # data.gov.in state consumption is reported in lakh MT (1 lakh = 100,000 t)
                    tonnes = lakh_mt * 100_000.0
                    for nutrient, pct in nutmap.items():
                        consumption_rows.append({
                            "source": "india_dof_state_consumption",
                            "source_record_id": (f"india_dof_state_consumption|IND|{state}|"
                                                 f"{nutrient}|{yr}|{prod_key}"),
                            "country_iso3": "IND", "country_name": "India",
                            "state_or_region": state,
                            "year": yr, "nutrient": nutrient,
                            "total_tonnes": tonnes * (pct / 100.0),
                            "kg_per_ha_arable": None, "arable_land_ha": None,
                            "source_url": src_url, "retrieved_at": retrieved_at,
                            "review_flags": f"derived_from_product_{prod_key}",
                        })
            if consumption_rows:
                cdf = pd.DataFrame(consumption_rows, columns=USE_COLS)
                rollup = (cdf.groupby(["country_iso3", "country_name", "state_or_region", "year", "nutrient"],
                                      as_index=False)
                          .agg({"total_tonnes": "sum",
                                "review_flags": lambda s: "derived_from_products:" + ",".join(sorted(set(
                                    ",".join(s).replace("derived_from_product_", "").split(","))))}))
                rollup["source"] = "india_dof_state_consumption"
                rollup["source_record_id"] = (rollup["source"] + "|IND|" + rollup["state_or_region"]
                                              + "|" + rollup["nutrient"] + "|" + rollup["year"].astype(str))
                rollup["kg_per_ha_arable"] = None
                rollup["arable_land_ha"] = None
                rollup["source_url"] = src_url
                rollup["retrieved_at"] = retrieved_at
                rollup = rollup[USE_COLS]
                use = pd.concat([use, rollup], ignore_index=True)
                log.info("india_dof_state_consumption rows: %d (from %d product-nutrient pairs)",
                         len(rollup), len(consumption_rows))
            else:
                log.info("india_dof_state_consumption rows: 0")
        except Exception as exc:  # noqa: BLE001
            log.warning("india_dof_state_consumption parse failed: %s", exc)

    # ── India DOF district N/P/K (data.gov.in resource 93051de3...) ─────────
    # 30 districts × {Nitrogen, Phosphorus, Potash, Total} tonnes for 2019-20.
    # Direct N/P/K — no stoichiometric derivation needed. Note: column header is
    # "Phosphorus" but India reporting convention treats this column as P2O5.
    if results.get("india_dof_district_npk") == "ok":
        src_url = "https://api.data.gov.in/resource/93051de3-ccea-45b1-8026-5836ae176b10"
        csv_path = staging / "india_dof" / "district_npk.csv"
        try:
            df = pd.read_csv(csv_path)

            def norm_col2(c: str) -> str:
                return re.sub(r"[^a-z0-9]+", "_", c.lower()).strip("_")

            df.columns = [norm_col2(c) for c in df.columns]
            dist_col = next((c for c in df.columns if "distric" in c), None)
            n_col = next((c for c in df.columns if "nitrogen" in c), None)
            p_col = next((c for c in df.columns if "phosphor" in c), None)
            k_col = next((c for c in df.columns if "potash" in c), None)
            district_rows: list[dict] = []
            if dist_col:
                for _, row in df.iterrows():
                    dist = str(row.get(dist_col, "")).strip()
                    if not dist or dist.lower() in ("nan", "total"):
                        continue
                    for col, nutrient in ((n_col, "N"), (p_col, "P2O5"), (k_col, "K2O")):
                        if not col:
                            continue
                        try:
                            v = float(row.get(col))
                        except (TypeError, ValueError):
                            continue
                        if pd.isna(v) or v == 0:
                            continue
                        district_rows.append({
                            "source": "india_dof_district_npk",
                            "source_record_id": f"india_dof_district_npk|IND|{dist}|{nutrient}|2019",
                            "country_iso3": "IND", "country_name": "India",
                            "state_or_region": dist,
                            "year": 2019, "nutrient": nutrient,
                            "total_tonnes": v,
                            "kg_per_ha_arable": None, "arable_land_ha": None,
                            "source_url": src_url, "retrieved_at": retrieved_at,
                            "review_flags": "district_level;year_2019_20_only",
                        })
            if district_rows:
                use = pd.concat([use, pd.DataFrame(district_rows, columns=USE_COLS)], ignore_index=True)
            log.info("india_dof_district_npk rows: %d", len(district_rows))
        except Exception as exc:  # noqa: BLE001
            log.warning("india_dof_district_npk parse failed: %s", exc)

    return prices, use


def preserve_failed_sources(df: pd.DataFrame, prev_path: Path, src_status: dict[str, str],
                            cols: list[str]) -> pd.DataFrame:
    if not prev_path.exists():
        return df
    try:
        prev = pd.read_parquet(prev_path)
    except Exception:  # noqa: BLE001
        return df
    failed = [k for k, v in src_status.items() if v != "ok"]
    if not failed:
        return df
    keep = prev[prev["source"].isin(failed)]
    if keep.empty:
        return df
    log.info("preserved %d rows for failed sources %s from %s", len(keep), failed, prev_path)
    return pd.concat([df, keep], ignore_index=True)[cols]


# ── MAIN ────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", default=str(Path(__file__).resolve().parent.parent / "data"),
                    help="Directory for prices/use parquet+csv (default: ../data)")
    ap.add_argument("--log-path", default=None,
                    help="Path to refresh_log.csv (default: <out-dir>/refresh_log.csv)")
    ap.add_argument("--skip", action="append", default=[],
                    help="Skip a source (repeatable). Valid: wb_pinksheet, africafertilizer, "
                         "faostat, faostat_product, owid, wb_wdi, india_dof")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    started = datetime.now(timezone.utc)
    retrieved_at = started.strftime("%Y-%m-%dT%H:%M:%SZ")

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path = Path(args.log_path) if args.log_path else (out_dir / "refresh_log.csv")

    prices_parquet = out_dir / "prices.parquet"
    use_parquet = out_dir / "use.parquet"

    staging = Path(tempfile.mkdtemp(prefix="fertilizer_market_"))
    afe_dir = staging / "afe"
    afe_dir.mkdir(parents=True, exist_ok=True)
    india_dir = staging / "india_dof"
    india_dir.mkdir(parents=True, exist_ok=True)
    log.info("[STAGING] %s", staging)

    skip = set(args.skip)
    results: dict[str, str] = {
        "wb_pinksheet": None, "africafertilizer": None,
        "faostat": None, "faostat_product": None,
        "owid": None, "wb_wdi": None, "india_dof": None,
        "india_dof_state_consumption": None,
        "india_dof_district_npk": None,
    }

    def _try(name: str, fn: Callable[[], None]) -> None:
        if name in skip:
            results[name] = "skipped"
            log.info("[SKIP] %s", name)
            return
        try:
            fn()
            results[name] = "ok"
        except Exception as exc:  # noqa: BLE001
            log.warning("[FAIL] %s: %s", name, exc)
            results[name] = f"fail: {exc}"

    _try("wb_pinksheet",     lambda: get_wb_pinksheet(staging / "pinksheet.xlsx"))
    _try("africafertilizer", lambda: get_africa_fertilizer(
        ["NGA", "ETH", "KEN", "TZA", "GHA", "MWI", "MOZ", "ZMB", "UGA", "SEN", "RWA"], afe_dir))
    _try("faostat",          lambda: get_faostat_nutrient(staging / "faostat.zip"))
    _try("faostat_product",  lambda: get_faostat_product(staging / "faostat_product.zip"))
    _try("owid",             lambda: get_owid(staging / "owid.csv"))
    _try("wb_wdi",           lambda: get_wb_wdi(staging / "wb_wdi.json"))
    _try("india_dof",        lambda: get_datagovin_dof(india_dir))
    _try("india_dof_state_consumption", lambda: get_datagovin_state_consumption(india_dir / "state_consumption.csv"))
    _try("india_dof_district_npk",      lambda: get_datagovin_district_npk(india_dir / "district_npk.csv"))

    try:
        prices, use = normalize(staging, results, retrieved_at)

        price_results = {k: results.get(k) for k in ("wb_pinksheet", "africafertilizer", "india_dof")}
        use_results = {k: results.get(k) for k in (
            "faostat", "faostat_product", "owid", "wb_wdi",
            "india_dof", "india_dof_state_consumption", "india_dof_district_npk")}
        prices = preserve_failed_sources(prices, prices_parquet, price_results, PRICE_COLS)
        use = preserve_failed_sources(use, use_parquet, use_results, USE_COLS)

        for col in ("year", "month"):
            if col in prices.columns:
                prices[col] = pd.to_numeric(prices[col], errors="coerce").astype("Int32")
        prices["price_usd_per_t"] = pd.to_numeric(prices["price_usd_per_t"], errors="coerce")
        prices["price_local_per_t"] = pd.to_numeric(prices["price_local_per_t"], errors="coerce")

        use["year"] = pd.to_numeric(use["year"], errors="coerce").astype("Int32")
        for c in ("total_tonnes", "kg_per_ha_arable", "arable_land_ha"):
            use[c] = pd.to_numeric(use[c], errors="coerce")

        prices[PRICE_COLS].to_parquet(prices_parquet, compression="snappy", index=False)
        prices[PRICE_COLS].to_csv(prices_parquet.with_suffix(".csv"), index=False, encoding="utf-8")
        use[USE_COLS].to_parquet(use_parquet, compression="snappy", index=False)
        use[USE_COLS].to_csv(use_parquet.with_suffix(".csv"), index=False, encoding="utf-8")

        wallclock = int((datetime.now(timezone.utc) - started).total_seconds())
        log.info("[DONE] wallclock=%ds prices=%d use=%d log=%s",
                 wallclock, len(prices), len(use), log_path)

        log_row = {
            "timestamp_utc": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "wallclock_seconds": wallclock,
            "prices_rows": len(prices),
            "use_rows": len(use),
            "sources_status": json.dumps(results, separators=(",", ":")),
            "exit_status": "ok",
        }
        log_existed = log_path.exists()
        with log_path.open("a", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=list(log_row))
            if not log_existed:
                writer.writeheader()
            writer.writerow(log_row)

        return 0
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
