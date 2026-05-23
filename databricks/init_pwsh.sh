#!/usr/bin/env bash
# init_pwsh.sh — Databricks cluster init script. Installs PowerShell 7 and the
# Databricks CLI, both required by the fertilizer-weekly-refresh job.
#
# Configured on the job's new_cluster.init_scripts. Lives in
# /Volumes/ggo_agdev/bioinputs/_staging/init_pwsh.sh (uploaded once; Databricks
# init scripts cannot be sourced from a git_source repo because they run
# before the repo checkout).
#
# Idempotent: each install short-circuits if already present.
set -euo pipefail

# ── PowerShell ───────────────────────────────────────────────────────────────
if dpkg --get-selections | grep -q '^powershell\s'; then
  echo "[init_pwsh] powershell already installed"
else
  DEB_URL="https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb"
  TMP_DEB="/tmp/packages-microsoft-prod.deb"
  echo "[init_pwsh] fetching MS repo config"
  curl -fsSL "$DEB_URL" -o "$TMP_DEB"
  dpkg -i "$TMP_DEB"
  rm -f "$TMP_DEB"
  echo "[init_pwsh] apt-get update + install powershell"
  apt-get update
  apt-get install -y --no-install-recommends powershell
  echo "[init_pwsh] pwsh: $(pwsh -Version)"
fi

# ── Databricks CLI ───────────────────────────────────────────────────────────
if command -v databricks >/dev/null 2>&1; then
  echo "[init_pwsh] databricks CLI already installed: $(databricks --version)"
else
  echo "[init_pwsh] installing databricks CLI"
  curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
  echo "[init_pwsh] databricks: $(databricks --version)"
fi

echo "[init_pwsh] init complete — wrapper sets DATABRICKS_HOST/TOKEN per-run"
