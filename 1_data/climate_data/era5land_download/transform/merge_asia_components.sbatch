#!/bin/bash
#SBATCH --job-name=era5_asia_combine
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --array=0-279%24

set -euo pipefail

# Merge India and asia_east annual daily files into asia_combined.
#
# One task is one variable-year pair. The array range must equal:
#   number of years * number of variables - 1.
#
# This is a compute-node job because it opens and writes NetCDF files.

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/transform
PYTHON=/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python
INPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily
OUTPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily
START_YEAR=1990
END_YEAR=2024
VARIABLES=(q_mean rh_mean swe_mean tmax tmean tmin tp_total wind_max)
N_VARIABLES=${#VARIABLES[@]}
EXPECTED_TASKS=$(((END_YEAR - START_YEAR + 1) * N_VARIABLES))
TASK_ID=${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is required}

if (( TASK_ID < 0 || TASK_ID >= EXPECTED_TASKS )); then
    echo "Invalid task ID ${TASK_ID}; expected 0-$((EXPECTED_TASKS - 1))" >&2
    exit 64
fi

YEAR=$((START_YEAR + TASK_ID / N_VARIABLES))
VARIABLE_INDEX=$((TASK_ID % N_VARIABLES))
VARIABLE=${VARIABLES[$VARIABLE_INDEX]}

if (( YEAR < START_YEAR || YEAR > END_YEAR )); then
    echo "Decoded year ${YEAR} is outside ${START_YEAR}-${END_YEAR}" >&2
    exit 64
fi
if (( (YEAR - START_YEAR) * N_VARIABLES + VARIABLE_INDEX != TASK_ID )); then
    echo "Task decoding self-check failed" >&2
    exit 64
fi

echo "job_id=${SLURM_JOB_ID}"
echo "array_task_id=${TASK_ID}"
echo "decoded_year=${YEAR}"
echo "decoded_variable_index=${VARIABLE_INDEX}"
echo "decoded_variable=${VARIABLE}"
echo "host=$(hostname)"
echo "start_time=$(date --iso-8601=seconds)"

"$PYTHON" \
    "$SCRIPT_DIR/merge_asia_components.py" \
    --variable "$VARIABLE" \
    --year "$YEAR" \
    --input-root "$INPUT_ROOT" \
    --output-root "$OUTPUT_ROOT" \
    --output-region asia_combined

echo "end_time=$(date --iso-8601=seconds)"
