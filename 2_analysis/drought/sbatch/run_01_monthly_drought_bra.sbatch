#!/bin/bash
#SBATCH --job-name=drought_monthly_bra
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.err
#SBATCH --time=02:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall_drought_branch"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
LOG_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs"

COUNTRIES="BRA"

mkdir -p "${LOG_DIR}"
cd "${REPO}"

# Build the Brazil monthly drought file from all available ERA5-Land monthly
# admin files. The current source coverage is 1960-2024.
# To run a different version, edit the settings inside the R script.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/monthly/era5land_admin_drought_monthly_bra.rds
"${RSCRIPT}" 2_analysis/drought/01_build_monthly_drought_measures.R \
  --countries="${COUNTRIES}" \
  --write
