#!/bin/bash
#SBATCH --job-name=era5_prcp_exp
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=24G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null
#SBATCH --array=0-14

# ======================================================================
# Build static admin precipitation exposure by country.
#
# The Slurm array loops over the country list below.
# Run the combine sbatch after all country tasks finish.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Slurm uses this index to pick one country from the list.
COUNTRIES=(BRA CHL CHN COL AUS ECU EU FRA IND JPN KOR MEX USA PHL PER)
COUNTRY=${COUNTRIES[$SLURM_ARRAY_TASK_ID]}

LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/admin_precip_exposure"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/admin_precip_exposure_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.out" \
     2>"$LOG_DIR/admin_precip_exposure_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY start=$(date --iso-8601=seconds)"
"$PYTHON" panel/03_admin_precip_exposure.py --country "$COUNTRY"
echo "end=$(date --iso-8601=seconds)"
