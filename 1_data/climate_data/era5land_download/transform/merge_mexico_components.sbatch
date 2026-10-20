#!/bin/bash
#SBATCH --job-name=mex_era5
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --array=0-279%8

set -euo pipefail

# Merge USA and mexico_south annual daily files into the mexico folder.
#
# One task is one variable-year pair. The output folder is still called
# `mexico`, although it covers a much larger North America domain.

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/transform
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
INPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily
OUTPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily

VARIABLES=(q_mean rh_mean swe_mean tmax tmean tmin tp_total wind_max)
START_YEAR=1990
END_YEAR=2024
N_YEARS=$((END_YEAR - START_YEAR + 1))

TASK=${SLURM_ARRAY_TASK_ID:?Submit as an array}
VAR_INDEX=$((TASK / N_YEARS))
YEAR_OFFSET=$((TASK % N_YEARS))
VARIABLE=${VARIABLES[$VAR_INDEX]}
YEAR=$((START_YEAR + YEAR_OFFSET))

export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK
export OPENBLAS_NUM_THREADS=$SLURM_CPUS_PER_TASK
export MKL_NUM_THREADS=$SLURM_CPUS_PER_TASK

echo "task=$TASK variable=$VARIABLE year=$YEAR host=$(hostname) start=$(date --iso-8601=seconds)"
set +e
"$PYTHON" "$SCRIPT_DIR/merge_mexico_components.py" \
    --variable "$VARIABLE" \
    --year "$YEAR" \
    --input-root "$INPUT_ROOT" \
    --output-root "$OUTPUT_ROOT" \
    --output-region mexico
STATUS=$?
set -e

if [[ "$STATUS" -eq 3 ]]; then
    echo "source_pair_not_ready_skip=true"
    exit 0
fi
if [[ "$STATUS" -ne 0 ]]; then
    echo "combine_failed_status=$STATUS"
    exit "$STATUS"
fi
echo "end=$(date --iso-8601=seconds)"
