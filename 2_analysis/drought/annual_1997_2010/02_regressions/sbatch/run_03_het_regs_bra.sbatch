#!/bin/bash
#SBATCH --job-name=drought_het_regs_bra
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=06:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.err

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
DROUGHT="${REPO}/2_analysis/drought/annual_1997_2010"

mkdir -p "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs"

# FE spec is the first argument: main or saturated.
# Usage, from the repo root:
#   sbatch 2_analysis/drought/annual_1997_2010/02_regressions/sbatch/run_03_het_regs_bra.sbatch saturated
FE_SPEC="${1:-main}"

# Heterogeneity runs (03_brazil_het_regs.R), then their figures
# (03_run_outputs/02_brazil_het_outputs.R). Urban and income in levels.
# Baseline climate (rainfall level and variability) in levels and Poisson. Each
# with and without the precip poly.
RUNS=(
  "--outcome_model=levels --het_defs=main"
  "--outcome_model=levels --het_defs=climate"
  "--outcome_model=poisson --het_defs=climate"
  "--outcome_model=levels --het_defs=main --prcp_poly=true"
  "--outcome_model=levels --het_defs=climate --prcp_poly=true"
  "--outcome_model=poisson --het_defs=climate --prcp_poly=true"
)

for run in "${RUNS[@]}"; do
  echo "=== ${FE_SPEC} ${run}"
  (cd "${DROUGHT}/02_regressions" && "${RSCRIPT}" 03_brazil_het_regs.R --fe_spec="${FE_SPEC}" --drought_vars=extended ${run})
  (cd "${DROUGHT}/03_run_outputs" && "${RSCRIPT}" 02_brazil_het_outputs.R --fe_spec="${FE_SPEC}" --drought_vars=extended ${run})
done
