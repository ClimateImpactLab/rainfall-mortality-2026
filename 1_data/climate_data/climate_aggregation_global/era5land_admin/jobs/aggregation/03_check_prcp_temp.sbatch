#!/bin/bash
#SBATCH --job-name=era5_check
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Check one country-year of ERA5-Land precipitation and temperature output.
#
# Use this when one annual file needs to be checked by hand.
# The main aggregation sbatch already runs this check after each year.
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

# $2 = year to check.
YEAR=$2

# Keep check logs next to the aggregation logs for this country.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this manual check.
exec >"$LOG_DIR/check_${SLURM_JOB_ID}_${YEAR}.out" \
     2>"$LOG_DIR/check_${SLURM_JOB_ID}_${YEAR}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY year=$YEAR start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/03_check_prcp_temp.py \
    --country "$COUNTRY" \
    --year "$YEAR"

echo "end=$(date --iso-8601=seconds)"
