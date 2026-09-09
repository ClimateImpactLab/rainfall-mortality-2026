#!/bin/bash
# Plot main response functions with daily rain-wind overlap checks

#SBATCH --job-name=rain_overlap_cmp
#SBATCH --account=cil
#SBATCH --partition=amd
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_overlap_cmp_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_overlap_cmp_%j.err

set -euo pipefail

# Repo and R environment
REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Options used to find the saved response-function files
OUTCOME_MODEL="${OUTCOME_MODEL:-poisson}"
SPEC_SET="${SPEC_SET:-main_two}"
WEIGHTED="${WEIGHTED:-true}"
PRCP_ORDER="${PRCP_ORDER:-3}"

# Make the daily overlap comparison figure
cd "${REPO}/2_analysis/figures"
"${RSCRIPT}" \
  06_compare_main_daily_overlap.R \
  --outcome_model="${OUTCOME_MODEL}" \
  --spec_set="${SPEC_SET}" \
  --weighted="${WEIGHTED}" \
  --prcp_order="${PRCP_ORDER}"
