#!/bin/bash
#SBATCH --job-name=rain_wind_combine
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Combine daily rain-event wind overlap files.
#
# Run this after run_08 has finished for all countries.
# Python reads the country files and writes one combined file.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the ERA5-Land aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Keep the combine log next to the other ERA5-Land logs.
LOG_DIR="$ROOT/logs/era5land_admin/combined"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this combine job.
exec >"$LOG_DIR/rain_event_wind_combine_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/rain_event_wind_combine_${SLURM_JOB_ID}.err"

# Make local imports work for panel scripts.
cd "$ROOT/era5land_admin"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:$PWD/diagnostics:$PWD/cell_fallback:$PWD/panel:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "start=$(date --iso-8601=seconds)"

"$PYTHON" panel/05_combine_rain_wind_events.py

echo "end=$(date --iso-8601=seconds)"
