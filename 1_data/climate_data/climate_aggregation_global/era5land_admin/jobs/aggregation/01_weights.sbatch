#!/bin/bash
#SBATCH --job-name=era5_wt
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
# Build one chunk of ERA5-Land weights for one country.
#
# The country shapefile can contain thousands of admin polygons.
# We split those polygons into chunks so several chunks can run in parallel.
# Example: BRA 20 means split Brazil's admin polygons into 20 chunks.
# This Slurm array task builds one of those chunks.
# These chunks are polygon groups, not years.
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

# $2 = number of polygon chunks for this country.
# BRA 20 means Brazil's admin polygons are divided into 20 groups.
N_CHUNKS=$2

# Slurm sets this from --array=0-19%10.
# Chunk 0 handles the first group of polygons, chunk 1 the next group, etc.
CHUNK=$SLURM_ARRAY_TASK_ID

# Keep weight logs separate by country and chunk.
LOG_DIR="$ROOT/logs/era5land_admin/$COUNTRY/weights"

# -----------------------------
# Logs and environment
# -----------------------------

mkdir -p "$LOG_DIR"

# One stdout/stderr pair for this chunk.
exec >"$LOG_DIR/job_${SLURM_ARRAY_JOB_ID}_${CHUNK}.out" \
     2>"$LOG_DIR/job_${SLURM_ARRAY_JOB_ID}_${CHUNK}.err"

# Make local imports work for common.py and settings.py.
cd "$ROOT/era5land_admin"
export PYTHONPATH="$PWD:$PWD/aggregation_scripts:${PYTHONPATH:-}"

# -----------------------------
# Run
# -----------------------------

# Write a short line to the .out log so we can see when and where this job ran.
# Print start/end times in the log so the runtime is easy to check.
echo "country=$COUNTRY chunks=$N_CHUNKS chunk=$CHUNK start=$(date --iso-8601=seconds)"

"$PYTHON" aggregation_scripts/01_make_weights.py \
    --country "$COUNTRY" \
    --jobs "$N_CHUNKS" \
    --job "$CHUNK" \
    --overwrite

# If this line is in the .out log, the Python script reached the end.
echo "end=$(date --iso-8601=seconds)"
