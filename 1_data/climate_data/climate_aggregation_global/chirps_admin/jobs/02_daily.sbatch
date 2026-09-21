#!/bin/bash
#SBATCH --job-name=chirps_adm
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
# Aggregate CHIRPS precipitation for one country-year.
#
# Submit this with a year array.
# Example: --array=1985-2024 runs one job for each year.
# Each year job writes daily, monthly, and annual admin-level files.
# After aggregation finishes, this sbatch also runs the country-year check.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the CHIRPS aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# $1 = country code, e.g. COL.
COUNTRY=$1

# Optional second argument: --overwrite.
OVERWRITE=${2:-}

# Slurm sets this from the year array.
YEAR=$SLURM_ARRAY_TASK_ID

# Keep precipitation logs separate by country and year.
LOG_DIR="$ROOT/logs/chirps_admin/$COUNTRY"

# -----------------------------
# Logs and environment
# -----------------------------

if [[ -n "$OVERWRITE" && "$OVERWRITE" != "--overwrite" ]]; then
    echo "Unknown second argument: $OVERWRITE" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this country-year.
exec >"$LOG_DIR/year_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/year_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/chirps_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

echo "country=$COUNTRY year=$YEAR start=$(date --iso-8601=seconds)"

if [[ "$OVERWRITE" == "--overwrite" ]]; then
    "$PYTHON" aggregation_scripts/02_aggregate_daily.py \
        --country "$COUNTRY" \
        --year "$YEAR" \
        --overwrite
else
    "$PYTHON" aggregation_scripts/02_aggregate_daily.py \
        --country "$COUNTRY" \
        --year "$YEAR"
fi

"$PYTHON" aggregation_scripts/03_check_outputs.py \
    --country "$COUNTRY" \
    --year "$YEAR"

echo "end=$(date --iso-8601=seconds)"
