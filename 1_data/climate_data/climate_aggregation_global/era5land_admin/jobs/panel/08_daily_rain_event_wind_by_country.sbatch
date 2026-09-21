#!/bin/bash
#SBATCH --job-name=rain_wind_cty
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null
#SBATCH --array=0-14

# ======================================================================
# Build daily rain-event wind overlap for one country.
#
# This is a panel-side check, not part of the main precipitation/temperature run.
# The Slurm array loops over the country list below.
# Each array task writes one country file.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the ERA5-Land aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Slurm uses this index to pick one country from the list.
COUNTRIES=(
  AUS BRA CHL CHN COL
  ECU EU FRA IND JPN
  KOR MEX PER PHL USA
)
COUNTRY=${COUNTRIES[$SLURM_ARRAY_TASK_ID]}

# Country outputs are written outside the repo.
OUT_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/combined/daily_rain_event_wind_overlap_by_country/$COUNTRY"

# Keep logs separate by country.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/rain_event_wind"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this country.
exec >"$LOG_DIR/rain_event_wind_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.out" \
     2>"$LOG_DIR/rain_event_wind_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"

# Make local imports work for panel scripts.
cd "$ROOT/era5land_admin"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY start=$(date --iso-8601=seconds)"

"$PYTHON" panel/04_rain_wind_events.py \
    --countries "$COUNTRY" \
    --output-dir "$OUT_DIR"

echo "end=$(date --iso-8601=seconds)"
