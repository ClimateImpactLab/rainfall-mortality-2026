#!/bin/bash
#SBATCH --job-name=era5_panel_clim
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=00:45:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Build the annual climate table used by the old panel merge.
#
# First export the old-panel admin-year ids.
# Then write the climate-to-panel crosswalk and panel-ready annual climate file.
# This is for the old panel only.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
STATA_LOG="$ROOT/logs/era5land_admin/export_panel_ids.log"
LOG_DIR="$ROOT/logs/era5land_admin/panel"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/panel_ready_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/panel_ready_${SLURM_JOB_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"

# Export the old-panel admin-year ids used by the climate crosswalk.
/software/stata-16-el8-x86_64/stata-mp -b do \
  "$ROOT/era5land_admin/panel/00_export_panel_ids.do"

# Stata writes r(#) in the log when a do-file fails.
if grep -Eq '^r\([0-9]+\);$' "$STATA_LOG"; then
  echo "Stata reported an error; see $STATA_LOG" >&2
  exit 1
fi

# Match ERA5-Land region IDs to the old panel and write the Stata climate file.
"$PYTHON" panel/01_link_panel_climate.py

echo "end=$(date --iso-8601=seconds)"
