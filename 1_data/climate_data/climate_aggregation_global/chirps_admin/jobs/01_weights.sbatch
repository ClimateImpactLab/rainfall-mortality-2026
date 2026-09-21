#!/bin/bash
#SBATCH --job-name=chirps_wt
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
# Build one chunk of CHIRPS weights for one country.
#
# The country shapefile can contain many admin polygons.
# We split those polygons into chunks so several chunks can run in parallel.
# Example: COL 20 means split Colombia's admin polygons into 20 chunks.
# This Slurm array task builds one of those chunks.
# These chunks are polygon groups, not years.
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

# $2 = number of polygon chunks for this country.
# COL 20 means Colombia's admin polygons are divided into 20 groups.
PARTS=$2

# Slurm sets this from --array=0-19%6.
# Chunk 0 handles the first group of polygons, chunk 1 the next group, etc.
PART=$SLURM_ARRAY_TASK_ID

# Keep weight logs separate by country and chunk.
LOG_DIR="$ROOT/logs/chirps_admin/$COUNTRY/weights"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this chunk.
exec >"$LOG_DIR/job_${SLURM_ARRAY_JOB_ID}_${PART}.out" \
     2>"$LOG_DIR/job_${SLURM_ARRAY_JOB_ID}_${PART}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/chirps_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

echo "country=$COUNTRY parts=$PARTS part=$PART start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/01_make_weights.py \
    --country "$COUNTRY" \
    --parts "$PARTS" \
    --part "$PART"

echo "end=$(date --iso-8601=seconds)"
