#!/bin/bash
#SBATCH --job-name=hydro_flow_monthly_preview
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
# Aggregate monthly routed flow (rainfall_flow) to admin
# units for one country-year.
#
# Submit from climate_aggregation_global with a year array.
# TEMPORARY PREVIEW: reads flow from hydro/coarse/prepflow_preview.py
# (latitude strips 0-4 only) and writes to hydro_preview/ instead of hydro/.
# Use jobs/01_monthly_flow.sbatch for the full global run.
# Preview pilot (USA, 2000):
#   sbatch --array=2000 hydro_era5land_admin/jobs/01_monthly_flow_preview.sbatch USA
# Needs the yearly flow files from hydro/coarse/prepflow.py.
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

LOG_DIR="$ROOT/logs/hydro_era5land_admin/$COUNTRY/preview/monthly"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this country-year.
exec >"$LOG_DIR/flow_monthly_${SLURM_ARRAY_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/flow_monthly_${SLURM_ARRAY_JOB_ID}_${YEAR}.err"

# settings.py, common.py, and wind_common.py come from era5land_admin.
# flow_common.py is in this folder.
cd "$ROOT/hydro_era5land_admin"
export PYTHONPATH="$ROOT/era5land_admin:$PWD:${PYTHONPATH:-}"

# Switch flow_common.py to the preview flow folder and hydro_preview/ outputs
export HYDRO_FLOW_PREVIEW=1

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY year=$YEAR start=$(date --iso-8601=seconds)"

"$PYTHON" 01_aggregate_monthly_flow.py \
    --country "$COUNTRY" \
    --year "$YEAR" \
    --overwrite

echo "end=$(date --iso-8601=seconds)"
