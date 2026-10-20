#!/bin/bash
#SBATCH --job-name=era5_usa_wind_cv
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=10G
#SBATCH --array=0-22%8
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/usa_missing_wind/convert_%A_%a.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/climate_data/era5land_download/logs/usa_missing_wind/convert_%A_%a.err

set -eo pipefail

# Convert missing USA monthly files into annual single-variable files.
# The output includes wind_max plus the other standard ERA5-Land daily variables.

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/transform
ENV_PATH=/project/cil/home_dirs/mdefranciosi/envs/era5land

INPUT_ROOT=/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily
OUTPUT_ROOT=/project/cil/gcp/climate/ERA5-LAND/raw/daily
REGION=usa
TASK_ID=${SLURM_ARRAY_TASK_ID}

if [ "$TASK_ID" -lt 18 ]; then
  YEAR=$((1950 + TASK_ID))
else
  YEAR=$((2011 + TASK_ID - 18))
fi

source ~/.bashrc
conda activate "$ENV_PATH"

echo "Region: $REGION"
echo "Year: $YEAR"
echo "Input root: $INPUT_ROOT"
echo "Output root: $OUTPUT_ROOT"

python "$SCRIPT_DIR/convert_monthly_to_annual_by_variable.py" \
  --region "$REGION" \
  --year "$YEAR" \
  --input-root "$INPUT_ROOT" \
  --output-root "$OUTPUT_ROOT"
