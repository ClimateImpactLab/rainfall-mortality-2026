#!/bin/bash
#SBATCH --job-name=us_state_wt
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# Build fixed U.S. state-to-ERA5-Land grid weights for the Young-Hsiang check.
# This reads LandScan and GPW files.

set -euo pipefail

# -----------------------------
# Paths and inputs
# -----------------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
LOG_DIR=/project/cil/gcp/estimation/rainfall-mortality/climate_data/logs/era5land_us_state_month

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/state_weights_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/state_weights_${SLURM_JOB_ID}.err"

export PYTHONDONTWRITEBYTECODE=1
cd "$ROOT"
export PYTHONPATH="$ROOT/era5land_admin:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

echo "start=$(date --iso-8601=seconds)"
"$PYTHON" era5land_us_state_month/01_make_state_weights.py
echo "end=$(date --iso-8601=seconds)"
