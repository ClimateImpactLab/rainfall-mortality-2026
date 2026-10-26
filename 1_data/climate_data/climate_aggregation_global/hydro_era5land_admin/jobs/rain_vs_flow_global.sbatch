#!/bin/bash
#SBATCH --job-name=rain_vs_flow_global
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=06:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=32G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Rainfall vs rainfall_flow statistics for every ERA5-Land land cell,
# one latitude band of the global grid per array task (bands 0-7).
#
# Submit from climate_aggregation_global:
#   sbatch --array=0-7 hydro_era5land_admin/jobs/rain_vs_flow_global.sbatch
# Needs the yearly flow files from hydro/coarse/prepflow.py and the band
# files from hydro/coarse/transform.py.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the ERA5-Land aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# Slurm sets this from the band array.
BAND=$SLURM_ARRAY_TASK_ID

LOG_DIR="$ROOT/logs/hydro_era5land_admin/GLOBAL/rain_vs_flow"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this band.
exec >"$LOG_DIR/cell_stats_${SLURM_ARRAY_JOB_ID}_band${BAND}.out" \
     2>"$LOG_DIR/cell_stats_${SLURM_ARRAY_JOB_ID}_band${BAND}.err"

# settings.py and common.py come from era5land_admin; flow_common.py is in
# hydro_era5land_admin.
cd "$ROOT/hydro_era5land_admin/rain_vs_flow"
export PYTHONPATH="$ROOT/era5land_admin:$ROOT/hydro_era5land_admin:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "band=$BAND start=$(date --iso-8601=seconds)"

"$PYTHON" 03_global_cell_stats.py \
    --band "$BAND" \
    --overwrite

echo "end=$(date --iso-8601=seconds)"
