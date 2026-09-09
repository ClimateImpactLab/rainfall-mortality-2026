#!/bin/bash
# Run the original Mumbai-profile regressions, then plot the response functions

#SBATCH --job-name=rain_subprof
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=4
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_subsample_profiles_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_subsample_profiles_%j.err

set -euo pipefail

# Repo and R environment
REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Options passed to the regression and plotting scripts
LOW_INCOME_CUTOFF="${LOW_INCOME_CUTOFF:-p25}"
OUTCOME_MODEL="${OUTCOME_MODEL:-levels}"
AGE_FILTER="${AGE_FILTER:-3}"
PROFILE_SCOPE="${PROFILE_SCOPE:-all}"
WIND_CONTROL="${WIND_CONTROL:-both}"
DAILY_OVERLAP_CONTROL="${DAILY_OVERLAP_CONTROL:-none}"
DAILY_OVERLAP_EXCLUSION="${DAILY_OVERLAP_EXCLUSION:-none}"

# Estimate the profile response functions
cd "${REPO}/2_analysis/regressions"
"${RSCRIPT}" \
  03_subsample_profiles.R \
  --low_income_cutoff="${LOW_INCOME_CUTOFF}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --age_filter="${AGE_FILTER}" \
  --profile_scope="${PROFILE_SCOPE}" \
  --wind_control="${WIND_CONTROL}" \
  --daily_overlap_control="${DAILY_OVERLAP_CONTROL}" \
  --daily_overlap_exclusion="${DAILY_OVERLAP_EXCLUSION}"

# Plot the response functions saved by the regression script
cd "${REPO}/2_analysis/figures"
"${RSCRIPT}" \
  03_plot_subsample_profiles.R \
  --low_income_cutoff="${LOW_INCOME_CUTOFF}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --age_filter="${AGE_FILTER}" \
  --profile_scope="${PROFILE_SCOPE}" \
  --wind_control="${WIND_CONTROL}" \
  --daily_overlap_control="${DAILY_OVERLAP_CONTROL}" \
  --daily_overlap_exclusion="${DAILY_OVERLAP_EXCLUSION}"
