#!/bin/bash
#SBATCH --job-name=era5_valid_cell
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ============================================================================
# Check or apply ERA5-Land small-cell fallback for one country.
#
# Some small island/coastal admin units have weights but missing climate cells.
# The fallback ID file lists the reviewed admin units to move to nearby cells.
# Use "check" first to write a detailed check CSV without changing weights.
# Use "apply" only when the check CSV looks right and weights should be changed.
# ============================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Arguments after the sbatch file:
#   $1 country code, for example CHL
#   $2 reviewed fallback ID CSV
#   $3 check or apply
#   $4 maximum allowed distance in degrees
COUNTRY=$1
FALLBACK_IDS=$2
ACTION=$3
MAX_DISTANCE=$4

# Optional:
#   $5 year of raw ERA5-Land files to inspect for masked cells.
# If omitted, Python uses the grid reference year from settings.py, usually 2000.
YEAR=${5:-}

LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/cell_fallback"
CHECK_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/cell_fallback_checks/$COUNTRY"
CHECK_CSV="$CHECK_DIR/${COUNTRY}_${ACTION}_${SLURM_JOB_ID}.csv"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR" "$CHECK_DIR"

exec >"$LOG_DIR/fallback_${ACTION}_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/fallback_${ACTION}_${SLURM_JOB_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY action=$ACTION start=$(date --iso-8601=seconds)"
echo "fallback_ids=$FALLBACK_IDS max_distance=$MAX_DISTANCE year=${YEAR:-default}"

# The third argument (ACTION=$3) chooses the mode passed to Python
# check = write the detailed check CSV only
# apply = write the same CSV and update the weight file
if [[ "$ACTION" == "check" ]]; then
    PYTHON_MODE=--check
elif [[ "$ACTION" == "apply" ]]; then
    PYTHON_MODE=--apply
else
    echo "Use action check or apply, not: $ACTION" >&2
    exit 2
fi

# Base Python command used by both modes.
CMD=(
    "$PYTHON" cell_fallback/step_02_apply_fallback.py
    --country "$COUNTRY"
    --region-id-file "$FALLBACK_IDS"
    --max-distance-degrees "$MAX_DISTANCE"
    --check-report "$CHECK_CSV"
    "$PYTHON_MODE"
)

# The year tells Python which raw ERA5-Land file to inspect for masked cells.
# Leaving it blank uses the grid year from settings.py.
if [[ -n "$YEAR" ]]; then
    CMD+=(--year "$YEAR")
fi

"${CMD[@]}"

# End time pairs with the start time above so runtime is easy to check.
echo "end=$(date --iso-8601=seconds)"
