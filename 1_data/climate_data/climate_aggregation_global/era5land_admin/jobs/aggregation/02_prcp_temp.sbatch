#!/bin/bash
#SBATCH --job-name=era5_adm
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Aggregate ERA5-Land precipitation and temperature for one country-year.
#
# Submit this with a year array.
# Example: --array=1950-2025 runs one job for each year.
# Each year job writes daily, monthly, and annual admin-level files.
# After the aggregation finishes, this sbatch also runs the country-year check.
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

# Keep precipitation/temperature logs separate by country and year.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this country-year.
exec >"$LOG_DIR/year_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/year_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY year=$YEAR start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/02_aggregate_prcp_temp.py \
    --country "$COUNTRY" \
    --year "$YEAR" \
    --overwrite

"$PYTHON" aggregation_scripts/03_check_prcp_temp.py \
    --country "$COUNTRY" \
    --year "$YEAR"

echo "end=$(date --iso-8601=seconds)"
