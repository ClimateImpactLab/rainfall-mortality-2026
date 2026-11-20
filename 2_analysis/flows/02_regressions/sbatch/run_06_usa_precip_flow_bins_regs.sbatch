#!/bin/bash
#SBATCH --job-name=precip_flow_bins_usa
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=03:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.err

set -euo pipefail

# Precip bins vs flow bins, USA, levels, saturated FE, death year only:
#   1. bin counts (01_measures/05_build_monthly_precip_flow_bins.R)
#   2. the 3 regs: baseline, precip bins, flow bins
#      (06_usa_precip_flow_bins_regs.R), saturated FE and, as a robustness
#      check, the main FE (no state x year x age)

REPO="/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026"
# R env of the other reg runners 
RSCRIPT="${RSCRIPT:-/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript}"
FLOWS="${REPO}/2_analysis/flows"

(cd "${FLOWS}/01_measures" && "${RSCRIPT}" 05_build_monthly_precip_flow_bins.R --write)
(cd "${FLOWS}/02_regressions" && "${RSCRIPT}" 06_usa_precip_flow_bins_regs.R --outcome_model=levels)
(cd "${FLOWS}/02_regressions" && "${RSCRIPT}" 06_usa_precip_flow_bins_regs.R --outcome_model=levels --spec=main)
