#!/bin/bash
#SBATCH --job-name=era5_wind
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Build annual ERA5-Land wind exposure for one country-year.
#
# Submit this with a year array.
# Example: --array=1950-2025 runs one job for each year.
# The script writes annual max wind and high-wind-day exposure.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the ERA5-Land aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# $1 = country code, e.g. BRA.
COUNTRY=$1

# Slurm sets this from the year array.
YEAR=$SLURM_ARRAY_TASK_ID

# Keep annual wind logs separate from precipitation/temperature logs.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/wind"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this country-year.
exec >"$LOG_DIR/wind_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/wind_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY year=$YEAR start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/05_aggregate_annual_wind.py \
    --country "$COUNTRY" \
    --year "$YEAR" \
    --overwrite

echo "end=$(date --iso-8601=seconds)"
