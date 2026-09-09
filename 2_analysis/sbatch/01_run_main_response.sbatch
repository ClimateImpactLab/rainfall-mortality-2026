#!/bin/bash
# Run the main rainfall and temperature regressions, then plot the response functions

#SBATCH --job-name=rain_main_rf
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_main_rf_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_main_rf_%j.err

set -euo pipefail

# Repo and R environment
REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Main regression options
# These are passed to 01_main_response.R and 01_plot_main_response.R
OUTCOME_MODEL="${OUTCOME_MODEL:-levels}"
RESPONSE="${RESPONSE:-both}"
SPEC_SET="${SPEC_SET:-main_two}"
CLIMATE_PRODUCT="${CLIMATE_PRODUCT:-ERA5LAND}"
WEIGHTED="${WEIGHTED:-true}"
PRCP_ORDER="${PRCP_ORDER:-3}"
WIND_CONTROL="${WIND_CONTROL:-both}"
DAILY_OVERLAP_CONTROL="${DAILY_OVERLAP_CONTROL:-none}"
DAILY_OVERLAP_EXCLUSION="${DAILY_OVERLAP_EXCLUSION:-none}"

# Estimate the response functions
cd "${REPO}/2_analysis/regressions"
"${RSCRIPT}" \
  01_main_response.R \
  --outcome_model="${OUTCOME_MODEL}" \
  --response="${RESPONSE}" \
  --spec_set="${SPEC_SET}" \
  --climate_product="${CLIMATE_PRODUCT}" \
  --weighted="${WEIGHTED}" \
  --prcp_order="${PRCP_ORDER}" \
  --wind_control="${WIND_CONTROL}" \
  --daily_overlap_control="${DAILY_OVERLAP_CONTROL}" \
  --daily_overlap_exclusion="${DAILY_OVERLAP_EXCLUSION}"

# Plot the response functions saved by the regression script
cd "${REPO}/2_analysis/figures"
"${RSCRIPT}" \
  01_plot_main_response.R \
  --outcome_model="${OUTCOME_MODEL}" \
  --response="${RESPONSE}" \
  --spec_set="${SPEC_SET}" \
  --weighted="${WEIGHTED}" \
  --prcp_order="${PRCP_ORDER}" \
  --wind_control="${WIND_CONTROL}" \
  --daily_overlap_control="${DAILY_OVERLAP_CONTROL}" \
  --daily_overlap_exclusion="${DAILY_OVERLAP_EXCLUSION}"
