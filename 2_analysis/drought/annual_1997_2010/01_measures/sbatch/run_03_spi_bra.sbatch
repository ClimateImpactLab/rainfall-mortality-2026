#!/bin/bash
#SBATCH --job-name=drought_spi_bra
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

# SPI measures (calendar-year SPI, worst 6-month SPI) from the monthly and
# annual drought files built by run_01 and run_02.
#
# Output:
# /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
# drought/brazil_annual/era5land_admin_spi_annual_bra.rds
cd "${DROUGHT}/01_measures"
"${RSCRIPT}" 03_build_spi_measures.R --write
