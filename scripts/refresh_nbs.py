"""refresh_nbs.py — Scrape India PIB press releases for Nutrient-Based Subsidy
(NBS) rate-change events. Emit canonical CSV/Parquet that conforms to the
fertilizer_price schema.

Python port of Refresh-IndiaNBS.ps1. PIB serves the rate table inline in older
press releases (2021-2023); newer releases (Kharif 2022+, Rabi 2024+) reference
a PDF annex instead. The script flags those with review_flags=
'manual_extract_required' so a follow-up scraper can target the annex.

Pipeline:
    READ SEED → FETCH HTML (cache) → PARSE column-major table → EMIT CANONICAL

Output schema matches gates_open_data.open_data.fertilizer_price:
    source           = 'india_pib_nbs'
    source_record_id = 'pib_nbs|<PRID>|<nutrient>|<YYYY-MM>'
    country_iso3     = 'IND'
    product          = 'N' | 'P' | 'K' | 'S'   (the nutrient)
    market_level     = 'subsidy_inr_per_kg'
    price_local_per_t = rate_inr_per_kg * 1000
    currency         = 'INR'
    review_flags     = 'parsed_from_html' | 'manual_extract_required'

Usage:
    python scripts/refresh_nbs.py
    python scripts/refresh_nbs.py --force-refetch

Requires: pandas, pyarrow, beautifulsoup4, lxml, requests.
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd
import requests

log = logging.getLogger("refresh_nbs")

PRICE_COLS = ['source', 'source_record_id', 'country_iso3', 'country_name', 'product',
              'product_grade', 'market_level', 'year', 'month', 'price_usd_per_t',
              'price_local_per_t', 'currency', 'source_url', 'retrieved_at', 'review_flags']

URL_TEMPLATES = (
    "https://pib.gov.in/PressReleasePage.aspx?PRID={prid}",
    "https://pib.gov.in/PressReleseDetailm.aspx?PRID={prid}",
)
USER_AGENT = "Mozilla/5.0 (compatible; fertilizer-market-canonical/1.0)"

# Column-header pattern. Anchored to header-cell shape, not free text.
NUTRIENT_PATTERNS = {
    "N": re.compile(r"^(n|nitrogen|n\s*\(nitrogen\))$", re.I),
    "P": re.compile(r"^(p|p2o5|phosphate|phosphor[a-z]*|p\s*\(phosphor[a-z]*\))$", re.I),
    "K": re.compile(r"^(k|k2o|potash|potassium|k\s*\(potash\))$", re.I),
    "S": re.compile(r"^(s|sulphur|sulfur|s\s*\(sulphur\))$", re.I),
}


def classify_nutrient(label: str) -> str | None:
    s = re.sub(r"\s+", " ", str(label).strip().lower())
    for nut, pat in NUTRIENT_PATTERNS.items():
        if pat.match(s):
            return nut
    return None


def parse_money_per_kg(cell_text: Any) -> float | None:
    if cell_text is None:
        return None
    s = re.sub(r"[,\s₹]", "", str(cell_text))
    s = re.sub(r"^(rs\.?|inr|₹)", "", s, flags=re.I)
    m = re.search(r"-?\d+(?:\.\d+)?", s)
    if not m:
        return None
    try:
        return float(m.group(0))
    except ValueError:
        return None


def month_from_season(season: str | None, announced_date: str | None) -> int | None:
    s = (season or "").strip().lower()
    if s == "kharif":
        return 4
    if s == "rabi":
        return 10
    if announced_date:
        try:
            return int(announced_date.split("-")[1])
        except (IndexError, ValueError):
            pass
    return None


def year_from_fy(fy: str | None, announced_date: str | None) -> int | None:
    if fy and re.match(r"^\d{4}", str(fy)):
        return int(str(fy)[:4])
    if announced_date:
        try:
            return int(announced_date.split("-")[0])
        except (IndexError, ValueError):
            pass
    return None


def read_seed(seed_csv: Path) -> list[dict]:
    rows: list[dict] = []
    with seed_csv.open(encoding="utf-8") as fh:
        for row in csv.DictReader((line for line in fh if not line.lstrip().startswith("#"))):
            if row.get("prid", "").strip().isdigit():
                rows.append(row)
    return rows


def fetch_html(prid: str, staging_dir: Path, force_refetch: bool) -> Path | None:
    dest = staging_dir / f"pib_{prid}.html"
    if dest.exists() and not force_refetch:
        size = dest.stat().st_size
        log.info("[FETCH] PRID=%s cached (%.1f KB) — skip", prid, size / 1024)
        return dest
    headers = {"User-Agent": USER_AGENT}
    for tpl in URL_TEMPLATES:
        url = tpl.format(prid=prid)
        for attempt in range(1, 4):
            try:
                r = requests.get(url, headers=headers, timeout=60)
                r.raise_for_status()
                if len(r.content) < 4 * 1024:
                    log.warning("[FETCH] PRID=%s from %s returned only %d bytes — trying fallback URL",
                                prid, url, len(r.content))
                    break
                dest.write_bytes(r.content)
                log.info("[FETCH] PRID=%s → %s (%.1f KB) from %s",
                         prid, dest, len(r.content) / 1024, url)
                return dest
            except Exception as exc:  # noqa: BLE001
                if attempt < 3:
                    log.warning("[FETCH] PRID=%s via %s attempt %d failed: %s",
                                prid, url, attempt, exc)
                    time.sleep(5)
                else:
                    log.warning("[FETCH] PRID=%s via %s failed: %s", prid, url, exc)
    return None


def parse_html(html: str, prid: str, year: int, month: int,
               retrieved_at: str) -> tuple[list[dict], dict]:
    from bs4 import BeautifulSoup  # local import — keeps the dependency optional

    diag = {"prid": prid, "tables_found": 0, "nutrient_rows": 0,
            "status": "", "reason": ""}
    source_url = f"https://pib.gov.in/PressReleasePage.aspx?PRID={prid}"
    soup = BeautifulSoup(html, "lxml")
    tables = soup.find_all("table")
    diag["tables_found"] = len(tables)

    emitted: set[str] = set()
    rows: list[dict] = []
    for tbl_idx, tbl in enumerate(tables):
        trs = tbl.find_all("tr")
        for ri, tr in enumerate(trs):
            cells = [td.get_text(" ", strip=True) for td in tr.find_all(["td", "th"])]
            if len(cells) < 2:
                continue
            nut_positions = [(ci, classify_nutrient(c)) for ci, c in enumerate(cells)
                             if classify_nutrient(c)]
            if len(nut_positions) < 2:
                continue
            if ri + 1 >= len(trs):
                continue
            data_cells = [td.get_text(" ", strip=True)
                          for td in trs[ri + 1].find_all(["td", "th"])]
            if len(data_cells) == len(cells) + 1:
                offset = 1
            elif len(data_cells) == len(cells):
                offset = 0
            else:
                first_numeric = next((i for i, c in enumerate(data_cells)
                                      if parse_money_per_kg(c) is not None), None)
                first_nut_col = nut_positions[0][0]
                offset = (first_numeric - first_nut_col) if first_numeric is not None else 0
            for ci, nut in nut_positions:
                if nut in emitted:
                    continue
                data_ci = ci + offset
                if data_ci < 0 or data_ci >= len(data_cells):
                    continue
                rate = parse_money_per_kg(data_cells[data_ci])
                if rate is None or rate <= 0:
                    continue
                flags = ["parsed_from_html"]
                if rate > 1000:
                    flags.append("magnitude_suspect_inr_per_mt")
                rows.append({
                    "source": "india_pib_nbs",
                    "source_record_id": f"pib_nbs|{prid}|{nut}|{year}-{month:02d}",
                    "country_iso3": "IND", "country_name": "India",
                    "product": nut, "product_grade": None,
                    "market_level": "subsidy_inr_per_kg",
                    "year": year, "month": month,
                    "price_usd_per_t": None,
                    "price_local_per_t": rate * 1000.0,
                    "currency": "INR",
                    "source_url": source_url, "retrieved_at": retrieved_at,
                    "review_flags": ";".join(flags) + f";table_idx={tbl_idx}",
                })
                emitted.add(nut)

    diag["nutrient_rows"] = len(rows)
    if not rows:
        diag["status"] = "no_rates_found"
        diag["reason"] = (f"{len(tables)} table(s) parsed but none matched "
                          f"nutrient row pattern; manual_extract_required")
        rows.append({
            "source": "india_pib_nbs",
            "source_record_id": f"pib_nbs|{prid}|UNRESOLVED|{year}-{month:02d}",
            "country_iso3": "IND", "country_name": "India",
            "product": None, "product_grade": None,
            "market_level": "subsidy_inr_per_kg",
            "year": year, "month": month,
            "price_usd_per_t": None, "price_local_per_t": None,
            "currency": "INR",
            "source_url": source_url, "retrieved_at": retrieved_at,
            "review_flags": "manual_extract_required",
        })
    else:
        diag["status"] = "parsed"
    return rows, diag


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out-dir", default=str(repo_root / "data"))
    ap.add_argument("--seed-csv", default=None,
                    help="Default: <out-dir>/canonical/nbs_pib_seeds.csv")
    ap.add_argument("--staging-dir", default=None,
                    help="HTML cache directory. Default: <out-dir>/india_pib_nbs")
    ap.add_argument("--force-refetch", action="store_true")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    seed_csv = Path(args.seed_csv) if args.seed_csv else out_dir / "canonical" / "nbs_pib_seeds.csv"
    staging_dir = Path(args.staging_dir) if args.staging_dir else out_dir / "india_pib_nbs"
    staging_dir.mkdir(parents=True, exist_ok=True)
    if not seed_csv.exists():
        log.error("Seed CSV not found: %s", seed_csv)
        return 2

    retrieved_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rates_csv = out_dir / "india_pib_nbs_rates.csv"
    rates_parquet = out_dir / "india_pib_nbs_rates.parquet"
    diag_csv = out_dir / "india_pib_nbs_diagnostic.csv"

    seed_rows = read_seed(seed_csv)
    if not seed_rows:
        log.warning("Seed CSV has no PRID rows. Populate %s and re-run.", seed_csv)
        return 0
    log.info("[SEED] %d PRID(s) to process from %s", len(seed_rows), seed_csv)

    all_rows: list[dict] = []
    all_diag: list[dict] = []
    for row in seed_rows:
        prid = row["prid"]
        announced = row.get("announced_date", "")
        season = row.get("season", "")
        fy = row.get("fiscal_year", "")
        html_path = fetch_html(prid, staging_dir, args.force_refetch)
        if not html_path:
            all_diag.append({
                "prid": prid, "announced_date": announced, "season": season,
                "tables_found": 0, "nutrient_rows": 0,
                "status": "fetch_failed", "reason": "all URL templates failed",
            })
            continue
        time.sleep(0.8)
        yr = year_from_fy(fy, announced)
        mo = month_from_season(season, announced)
        if yr is None or mo is None:
            all_diag.append({
                "prid": prid, "announced_date": announced, "season": season,
                "tables_found": 0, "nutrient_rows": 0,
                "status": "skipped",
                "reason": "cannot resolve effective year/month from seed row",
            })
            continue
        html = html_path.read_text(encoding="utf-8", errors="replace")
        rows, diag = parse_html(html, prid, yr, mo, retrieved_at)
        diag.update({"announced_date": announced, "season": season})
        all_rows.extend(rows)
        all_diag.append(diag)

    df = pd.DataFrame(all_rows, columns=PRICE_COLS)
    df.to_csv(rates_csv, index=False, encoding="utf-8")
    df.to_parquet(rates_parquet, compression="snappy", index=False)
    pd.DataFrame(all_diag).to_csv(diag_csv, index=False, encoding="utf-8")

    resolved = int(df["product"].notna().sum())
    unresolved = int(df["product"].isna().sum())
    log.info("")
    log.info("[DONE] %d row(s) in %s", len(df), rates_csv)
    log.info("       resolved nutrient rates: %d", resolved)
    log.info("       unresolved (manual_extract_required): %d", unresolved)
    log.info("[DONE] diagnostic: %s", diag_csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
