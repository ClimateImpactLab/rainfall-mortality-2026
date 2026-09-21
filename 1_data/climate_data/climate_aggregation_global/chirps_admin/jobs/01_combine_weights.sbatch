#!/bin/bash
#SBATCH --job-name=chirps_wt_combine
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

# ======================================================================
# Combine CHIRPS weight chunks for one country.
#
# Run this once after every chunk from 01_weights.sbatch has finished.
# Python reads the chunk files and writes the final weight and admin-summary
# files. Example: COL 20 means combine the 20 Colombia weight chunks.
# ======================================================================

set -euo pipefail

# ----------------------
# Paths and sbatch inputs
# ----------------------

# Root is the folder where sbatch was submitted.
ROOT=$(cd "$SLURM_SUBMIT_DIR" && pwd)

# Python environment used for the CHIRPS aggregation code.
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python

# $1 = country code, e.g. COL.
COUNTRY=$1

# $2 = number of polygon chunks that were built for this country.
PARTS=$2

# Keep combine logs next to the chunk logs.
LOG_DIR="$ROOT/logs/chirps_admin/$COUNTRY/weights"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for the combine job.
exec >"$LOG_DIR/combine_${SLURM_JOB_ID}.out" \
     2>"$LOG_DIR/combine_${SLURM_JOB_ID}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/chirps_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

echo "country=$COUNTRY parts=$PARTS start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/01_make_weights.py \
    --country "$COUNTRY" \
    --parts "$PARTS" \
    --combine

"$PYTHON" aggregation_scripts/03_check_outputs.py \
    --country "$COUNTRY"

echo "end=$(date --iso-8601=seconds)"
