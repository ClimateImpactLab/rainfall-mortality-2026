#!/bin/bash
#SBATCH --job-name=era5_prcp_exposure
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=48G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Build static admin precipitation exposure variables.
#
# This is a panel-side file, not part of the main annual climate table.
# It uses population weights to summarize extreme precipitation exposure.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
LOG_DIR="$ROOT/logs/era5land_admin/panel"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/admin_precip_exposure_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/admin_precip_exposure_${SLURM_JOB_ID}.err"

cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"
"$PYTHON" panel/03_admin_precip_exposure.py
echo "end=$(date --iso-8601=seconds)"
