#!/bin/bash
#SBATCH --job-name=drought_panel_bra
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.err

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
DROUGHT="${REPO}/2_analysis/drought/annual_1997_2010"

mkdir -p "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs"

# Brazil mortality + drought panel for the regs. Needs the yearly drought and
# SPI files from the 01_measures sbatch files.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_annual/brazil_annual_drought_regression_panel_urban.rds
cd "${DROUGHT}/02_regressions"
"${RSCRIPT}" 01_build_brazil_panel.R --write
