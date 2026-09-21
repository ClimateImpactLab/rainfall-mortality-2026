#!/bin/bash
#SBATCH --job-name=era5_wind_combine
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
# Combine annual ERA5-Land wind files.
#
# Run this after the annual wind country-year jobs are finished.
# Python writes the combined wind CSV and a coverage CSV.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the ERA5-Land aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Keep combined-file logs in one shared folder.
LOG_DIR="$ROOT/logs/era5land_admin/combined"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this combine job.
exec >"$LOG_DIR/combine_wind_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/combine_wind_${SLURM_JOB_ID}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/06_combine_annual_wind.py

echo "end=$(date --iso-8601=seconds)"
