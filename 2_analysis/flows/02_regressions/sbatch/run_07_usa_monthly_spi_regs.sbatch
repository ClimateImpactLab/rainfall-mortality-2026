#!/bin/bash
#SBATCH --job-name=monthly_spi_usa
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.err

set -euo pipefail

# The monthly-built terms in one run, USA, levels, saturated FE, death year only:
#   1. raw-level bin counts and county-percentile bin counts, the two schemes of
#      01_measures/05_build_monthly_precip_flow_bins.R (levels is the default scheme)
#   2. SPI-1 bin counts, weighted dry and wet sums, the two-sided SPI-12 and the squared
#      z-score sums, uncapped and capped (01_measures/06_build_monthly_spi_measures.R)
#   3. the regs: baseline and the sets for precip and flow
#      (07_usa_monthly_spi_regs.R: raw bins, county-percentile bins, SPI bin counts, SPI-12, weighted sums,
#      squared z-score sums uncapped and capped),
#      saturated FE and, as a robustness check, the main FE (no state x year x age)
# Time limit: the measured run took about 5 minutes (sacct: 5m04s).

REPO="/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026"
# R env of the other reg runners
RSCRIPT="${RSCRIPT:-/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript}"
FLOWS="${REPO}/2_analysis/flows"

(cd "${FLOWS}/01_measures" && "${RSCRIPT}" 05_build_monthly_precip_flow_bins.R --write)
(cd "${FLOWS}/01_measures" && "${RSCRIPT}" 05_build_monthly_precip_flow_bins.R --scheme=percentile --probs=0.1,0.25,0.75,0.9 --write)
(cd "${FLOWS}/01_measures" && "${RSCRIPT}" 06_build_monthly_spi_measures.R --write)
(cd "${FLOWS}/02_regressions" && "${RSCRIPT}" 07_usa_monthly_spi_regs.R --outcome_model=levels)
(cd "${FLOWS}/02_regressions" && "${RSCRIPT}" 07_usa_monthly_spi_regs.R --outcome_model=levels --spec=main)
