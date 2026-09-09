#!/bin/bash
# Estimate wind-control coefficients, then plot them

#SBATCH --job-name=rain_wind_coef
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=02:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=1
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_wind_coef_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_wind_coef_%j.err

set -euo pipefail

# Repo and R environment
REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Options passed to the regression and plotting scripts
SCOPE="${SCOPE:-both}"
OUTCOME_MODEL="${OUTCOME_MODEL:-poisson}"
SPEC_SET="${SPEC_SET:-main_two}"
WEIGHTED="${WEIGHTED:-true}"
PRCP_ORDER="${PRCP_ORDER:-3}"
INCOME_SCREEN="${INCOME_SCREEN:-p25}"
CONTROL_SET="${CONTROL_SET:-all}"
COUNTRY_GROUP="${COUNTRY_GROUP:-none}"

# Estimate coefficients on the wind and rain-wind overlap controls
cd "${REPO}/2_analysis/regressions"
"${RSCRIPT}" \
  05_wind_control_coefficients.R \
  --scope="${SCOPE}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --spec_set="${SPEC_SET}" \
  --weighted="${WEIGHTED}" \
  --prcp_order="${PRCP_ORDER}" \
  --income_screen="${INCOME_SCREEN}" \
  --control_set="${CONTROL_SET}" \
  --country_group="${COUNTRY_GROUP}"

# Plot the coefficient table written above
cd "${REPO}/2_analysis/figures"
"${RSCRIPT}" \
  07_plot_wind_control_coefficients.R \
  --scope="${SCOPE}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --spec_set="${SPEC_SET}" \
  --weighted="${WEIGHTED}" \
  --prcp_order="${PRCP_ORDER}" \
  --income_screen="${INCOME_SCREEN}" \
  --control_set="${CONTROL_SET}" \
  --country_group="${COUNTRY_GROUP}"
