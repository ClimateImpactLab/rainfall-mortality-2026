#!/bin/bash
#SBATCH --job-name=era5_fb_ids
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=00:15:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Write the ERA5-Land fallback ID CSVs.
#
# This writes the reviewed region_id lists used by step_02_apply_fallback.py.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

LOG_DIR="$ROOT/logs/era5land_admin/cell_fallback"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

exec >"$LOG_DIR/make_fallback_ids_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/make_fallback_ids_${SLURM_JOB_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/cell_fallback:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"
"$PYTHON" cell_fallback/step_01_make_fallback_ids.py
echo "end=$(date --iso-8601=seconds)"
