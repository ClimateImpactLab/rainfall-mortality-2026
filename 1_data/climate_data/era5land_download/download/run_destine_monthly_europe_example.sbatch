#!/bin/bash
#SBATCH --job-name=era5land_destine_europe
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --array=0-251%8

set -eo pipefail

# DestinE monthly download example for a regular region.
#
# One array task downloads one month.
# This example covers Europe from 1990 through 2010.
# That is 21 years * 12 months = 252 tasks, so the array is 0-251.
#
# Before submitting:
#   1. Check REGION, START_YEAR, END_YEAR.
#   2. Check the Slurm array length above.
#   3. Make sure ~/.env_destine exists and contains EDH_TOKEN.
#
# To make ~/.env_destine:
#   nano ~/.env_destine
#   export EDH_TOKEN='PASTE_KEY_HERE'
#   chmod 600 ~/.env_destine

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/download
DATA_ROOT=/project/cil/battuta_shares/gcp/climate/ERA5-LAND
BBOX_FILE=/project/cil/gcp/estimation/rainfall-mortality/era5land_domains/data/bbox/regional_era5land_bounding_boxes.gpkg
ENV_PATH=/project/cil/home_dirs/mdefranciosi/envs/era5land

# Edit these three lines for a different regular region.
REGION=europe
START_YEAR=1990
END_YEAR=2010

# Convert the array task number into a year and month.
TASK_ID=${SLURM_ARRAY_TASK_ID}
YEAR=$((START_YEAR + TASK_ID / 12))
MONTH=$((TASK_ID % 12 + 1))

if [ "$YEAR" -gt "$END_YEAR" ]; then
  echo "Task $TASK_ID maps beyond END_YEAR=$END_YEAR; exiting."
  exit 0
fi

SCRATCH_ROOT="${SLURM_TMPDIR:-/tmp/${USER}/era5land_destine_${REGION}_${SLURM_JOB_ID}_${TASK_ID}}"

# Load the Python environment and the DestinE key.
source ~/.bashrc
conda activate "$ENV_PATH"
source ~/.env_destine

echo "Region: $REGION"
echo "Year/month: $YEAR-$MONTH"
echo "BBOX file: $BBOX_FILE"
echo "Scratch: $SCRATCH_ROOT"
echo "EDH_TOKEN loaded? ${EDH_TOKEN:+yes}"

python -u "$SCRIPT_DIR/download_era5land_destine_month_region.py" \
  --year "$YEAR" \
  --month "$MONTH" \
  --region "$REGION" \
  --bbox-file "$BBOX_FILE" \
  --data-root "$DATA_ROOT" \
  --scratch-root "$SCRATCH_ROOT"
