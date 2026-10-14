#!/bin/bash
#SBATCH --job-name=drought_monthly_bra
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs/%x_%j.err
#SBATCH --time=08:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
LOG_DIR="/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/logs"

COUNTRIES="BRA"

mkdir -p "${LOG_DIR}"
cd "${REPO}"

# Monthly drought measures for each Brazil municipality, from the ERA5-Land
# monthly rainfall files (1960-2024). To run a different version, edit the
# settings in the R script.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/monthly/era5land_admin_drought_monthly_bra.rds
"${RSCRIPT}" 2_analysis/drought/annual_1997_2010/01_measures/01_build_monthly_drought_measures.R \
  --countries="${COUNTRIES}" \
  --write
