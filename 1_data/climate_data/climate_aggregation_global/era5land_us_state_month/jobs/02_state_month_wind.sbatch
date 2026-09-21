#!/bin/bash
#SBATCH --job-name=us_st_wind_m
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# Aggregate one year of ERA5-Land daily wind to U.S. state-month values.
# Submit with a year array, for example --array=1950-2015%6.

set -euo pipefail

# -----------------------------
# Paths and inputs
# -----------------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
YEAR=${SLURM_ARRAY_TASK_ID:?Submit this file with a year array}
OVERWRITE=${1:-}
LOG_DIR=/project/cil/gcp/estimation/rainfall-mortality/climate_data/logs/era5land_us_state_month/monthly_wind

if [[ -n "$OVERWRITE" && "$OVERWRITE" != "--overwrite" ]]; then
    echo "Unknown argument: $OVERWRITE" >&2
    exit 2
fi

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/state_month_wind_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/state_month_wind_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

export PYTHONDONTWRITEBYTECODE=1
cd "$ROOT"
export PYTHONPATH="$ROOT/era5land_admin:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

echo "year=$YEAR start=$(date --iso-8601=seconds)"
ARGS=(--year "$YEAR")
if [[ "$OVERWRITE" == "--overwrite" ]]; then
    ARGS+=(--overwrite)
fi
"$PYTHON" era5land_us_state_month/02_aggregate_monthly_wind.py "${ARGS[@]}"
echo "end=$(date --iso-8601=seconds)"
