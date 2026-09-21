#!/bin/bash
#SBATCH --job-name=era5_wt_combine
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Combine ERA5-Land weight chunks for one country.
#
# Run this only after every chunk from 01_weights.sbatch has finished.
# Python reads the chunk files and writes the final weight files.
# Example: BRA 20 means combine the 20 Brazil weight chunks.
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

# $2 = number of polygon chunks that were built for this country.
N_CHUNKS=$2

# Keep combine logs next to the chunk logs.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/weights"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for the combine job.
exec >"$LOG_DIR/combine_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/combine_${SLURM_JOB_ID}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY chunks=$N_CHUNKS start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/01_make_weights.py \
    --country "$COUNTRY" \
    --jobs "$N_CHUNKS" \
    --combine \
    --overwrite

echo "end=$(date --iso-8601=seconds)"
