#!/bin/bash
#SBATCH --job-name=era5_convert_annual_wind
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=10G
#SBATCH --array=0-74%8

set -eo pipefail

# Convert one region from monthly multi-variable daily files to annual
# single-variable daily files.
#
# One array task is one year. Edit REGION, START_YEAR, END_YEAR, and the Slurm
# array range together before submitting.
#
# Example:
#   Europe 1950-2024 uses START_YEAR=1950, END_YEAR=2024, array=0-74.

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/transform
ENV_PATH=/project/cil/home_dirs/mdefranciosi/envs/era5land

INPUT_ROOT=/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily
OUTPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily

source ~/.bashrc
conda activate "$ENV_PATH"

REGION=europe
START_YEAR=1990
END_YEAR=2024

TASK_ID=${SLURM_ARRAY_TASK_ID}
YEAR=$((START_YEAR + TASK_ID))

if [ "$YEAR" -gt "$END_YEAR" ]; then
    echo "Computed YEAR=$YEAR is greater than END_YEAR=$END_YEAR. Exiting."
    exit 0
fi

echo "===== JOB INFO ====="
echo "Host: $(hostname)"
echo "Start time: $(date)"
echo "SLURM job ID: $SLURM_JOB_ID"
echo "Array task ID: $TASK_ID"
echo "Region: $REGION"
echo "Start year: $START_YEAR"
echo "End year: $END_YEAR"
echo "Year: $YEAR"
echo "Script dir: $SCRIPT_DIR"
echo "Input root: $INPUT_ROOT"
echo "Output root: $OUTPUT_ROOT"
echo "Env: $ENV_PATH"
echo

echo "===== PYTHON ====="
which python
python --version
echo

echo "===== IMPORT TEST ====="
python -c "import xarray, netCDF4, numpy, pandas, dask; print('imports ok')"
echo

echo "===== INPUT CHECK ====="
echo "Expected input directory:"
echo "$INPUT_ROOT/$REGION/$YEAR"
echo

ls -lh "$INPUT_ROOT/$REGION/$YEAR"/era5land_daily_${REGION}_${YEAR}_*.nc | head
echo

echo "===== RUNNING CONVERSION ====="

python "$SCRIPT_DIR/convert_monthly_to_annual_by_variable.py" \
    --region "$REGION" \
    --year "$YEAR" \
    --input-root "$INPUT_ROOT" \
    --output-root "$OUTPUT_ROOT"

echo
echo "End time: $(date)"
echo "Job completed successfully."
