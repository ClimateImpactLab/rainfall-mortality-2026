#!/bin/bash
#SBATCH --job-name=era5land_cds
#SBATCH --account=cil
#SBATCH --partition=caslake
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --array=0-11%1

set -eo pipefail

# CDS monthly download template.
#
# One array task downloads one month.
# This template is limited to one running task at a time. In practice, many
# parallel CDS requests under the same API key were slow and queued.
#
# Before submitting:
#   1. Check REGION, START_YEAR, END_YEAR.
#   2. Check the Slurm array length above.
#   3. Check CDSAPI_RC points to the right CDS API key file.

REPO_ROOT=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
SCRIPT_DIR=$REPO_ROOT/1_data/climate_data/era5land_download/download
DATA_ROOT=/project/cil/battuta_shares/gcp/climate/ERA5-LAND
BBOX_FILE=/project/cil/gcp/estimation/rainfall-mortality/era5land_domains/data/bbox/regional_era5land_bounding_boxes.gpkg
ENV_PATH=/project/cil/home_dirs/mdefranciosi/envs/era5land

# Edit these three lines for the region/year span.
REGION=india
START_YEAR=1990
END_YEAR=1990

# Convert the array task number into a year and month.
TASK_ID=${SLURM_ARRAY_TASK_ID}
YEAR=$((START_YEAR + TASK_ID / 12))
MONTH=$((TASK_ID % 12 + 1))

if [ "$YEAR" -gt "$END_YEAR" ]; then
  echo "Task $TASK_ID maps beyond END_YEAR=$END_YEAR; exiting."
  exit 0
fi

SCRATCH_ROOT="${SLURM_TMPDIR:-/tmp/${USER}/era5land_cds_${REGION}_${SLURM_JOB_ID}_${TASK_ID}}"

# Load the Python environment.
source ~/.bashrc
conda activate "$ENV_PATH"

# Choose the CDS API config for this job.
export CDSAPI_RC=~/.cdsapirc

echo "Region: $REGION"
echo "Year/month: $YEAR-$MONTH"
echo "BBOX file: $BBOX_FILE"
echo "Scratch: $SCRATCH_ROOT"

python -u "$SCRIPT_DIR/download_era5land_cds_month_region.py" \
  --year "$YEAR" \
  --month "$MONTH" \
  --region "$REGION" \
  --bbox-file "$BBOX_FILE" \
  --data-root "$DATA_ROOT" \
  --scratch-root "$SCRATCH_ROOT" \
  --max-retries 5 \
  --retry-wait-seconds 180
