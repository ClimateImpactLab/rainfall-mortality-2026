#!/bin/bash
#SBATCH --job-name=drought_annual_bra
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=02:00:00
#SBATCH --mem=32G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.err

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall_drought_branch"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
LOG_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs"

MONTHLY_ROOT="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/monthly"
MONTHLY_FILES="${MONTHLY_ROOT}/era5land_admin_drought_monthly_bra.rds"

mkdir -p "${LOG_DIR}"
cd "${REPO}"

# Collapse the Brazil monthly drought file to one admin-year file.
# The annual file is still climate-only. It is not merged into mortality here.
# To run a different version, edit the settings inside the R script.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/annual/era5land_admin_drought_annual_bra.rds
"${RSCRIPT}" 2_analysis/drought/02_build_annual_drought_summaries.R \
  --monthly-files="${MONTHLY_FILES}" \
  --write
