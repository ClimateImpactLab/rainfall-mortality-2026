#!/bin/bash
#SBATCH --job-name=drought_annual_bra
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --mem=32G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.err

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
LOG_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs"

MONTHLY_ROOT="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/monthly"
MONTHLY_FILES="${MONTHLY_ROOT}/era5land_admin_drought_monthly_bra.rds"

mkdir -p "${LOG_DIR}"
cd "${REPO}"

# Yearly drought measures for each Brazil municipality, from the monthly
# drought file. To run a different version, edit the settings in the R script.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/annual/era5land_admin_drought_annual_bra.rds
"${RSCRIPT}" 2_analysis/drought/annual_1997_2010/01_measures/02_build_annual_drought_summaries.R \
  --monthly-files="${MONTHLY_FILES}" \
  --write
