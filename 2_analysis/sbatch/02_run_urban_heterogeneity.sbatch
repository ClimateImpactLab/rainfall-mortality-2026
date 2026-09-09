#!/bin/bash
# Run the urban-share regressions, then plot the response functions

#SBATCH --job-name=rain_urban_rf
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=03:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=24G
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_urban_rf_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/logs/rain_urban_rf_%j.err

set -euo pipefail

# Repo and R environment
REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Options passed to the regression and plotting scripts
WEIGHTED="${WEIGHTED:-true}"
OUTCOME_MODEL="${OUTCOME_MODEL:-levels}"
URBAN_DEFS="${URBAN_DEFS:-all}"

# Estimate the urban-share response functions
cd "${REPO}/2_analysis/regressions"
"${RSCRIPT}" \
  02_urban_heterogeneity.R \
  --weighted="${WEIGHTED}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --urban_defs="${URBAN_DEFS}"

# Plot the response functions saved by the regression script
cd "${REPO}/2_analysis/figures"
"${RSCRIPT}" \
  02_plot_urban_heterogeneity.R \
  --weighted="${WEIGHTED}" \
  --outcome_model="${OUTCOME_MODEL}" \
  --urban_defs="${URBAN_DEFS}"
