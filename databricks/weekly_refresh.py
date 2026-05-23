"""
weekly_refresh.py — Databricks Job entrypoint (spark_python_task).

Pulled from the H1nokam1Kagura/fertilizer_market Git source on each scheduled
run. Subprocess-execs the existing PowerShell refresh + load pipeline:

    1. scripts/Refresh-FertilizerMarket.ps1   — pulls upstream sources, writes data/*.parquet
    2. databricks/Load-FertilizerMarket.ps1   — INSERT OVERWRITE to ggo_agdev.bioinputs.fertilizer_*

Requires pwsh on the cluster. Install via the companion init script
databricks/init_pwsh.sh (configured on the job's new_cluster.init_scripts).

Exit code propagated from the underlying scripts. Non-zero fails the job.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def _resolve_repo_root() -> Path:
    here = Path(__file__).resolve().parent
    return here.parent


def _run(label: str, args: list[str], cwd: Path, env: dict[str, str]) -> None:
    print(f"[{label}] {' '.join(args)}", flush=True)
    r = subprocess.run(args, cwd=str(cwd), env=env)
    if r.returncode != 0:
        raise SystemExit(f"[{label}] exit {r.returncode}")
    print(f"[{label}] ok", flush=True)


def _databricks_env() -> dict[str, str]:
    """Extract workspace host + token from the running job context so the
    subprocess'd databricks CLI calls authenticate without a .databrickscfg.
    """
    env = dict(os.environ)
    try:
        from pyspark.sql import SparkSession  # noqa: WPS433 (job runtime only)
        from pyspark.dbutils import DBUtils  # type: ignore[import-not-found]

        spark = SparkSession.builder.getOrCreate()
        dbutils = DBUtils(spark)
        ctx = dbutils.notebook.entry_point.getDbutils().notebook().getContext()
        env["DATABRICKS_HOST"] = ctx.apiUrl().get()
        env["DATABRICKS_TOKEN"] = ctx.apiToken().get()
        print(f"[weekly_refresh] DATABRICKS_HOST={env['DATABRICKS_HOST']}", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[weekly_refresh] WARN could not derive DB credentials: {e}", flush=True)
    return env


def main() -> None:
    repo = _resolve_repo_root()
    print(f"[weekly_refresh] repo={repo}", flush=True)

    pwsh = shutil.which("pwsh")
    if not pwsh:
        raise SystemExit(
            "[weekly_refresh] pwsh not found — configure init_pwsh.sh on the job cluster"
        )
    print(f"[weekly_refresh] pwsh={pwsh}", flush=True)

    env = _databricks_env()
    profile = env.get("DATABRICKS_PROFILE", "DEFAULT")
    out_dir = env.get("FERTILIZER_OUT_DIR", str(repo / "data"))
    log_path = str(Path(out_dir) / "refresh_log.csv")

    _run(
        "refresh",
        [pwsh, "-NoProfile", "-File", str(repo / "scripts" / "Refresh-FertilizerMarket.ps1"),
         "-OutDir", out_dir, "-LogPath", log_path, "-Profile", profile],
        cwd=repo,
        env=env,
    )

    _run(
        "load",
        [pwsh, "-NoProfile", "-File", str(repo / "databricks" / "Load-FertilizerMarket.ps1"),
         "-DataDir", out_dir, "-Profile", profile],
        cwd=repo,
        env=env,
    )

    print("[weekly_refresh] done", flush=True)


if __name__ == "__main__":
    main()
