#!/bin/bash
#SBATCH --job-name=drought_regs_bra
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

# Pooled Brazil runs. For each run: the regs (02_brazil_regs.R), then its
# tables and figure (03_run_outputs/01_brazil_reg_outputs.R).
# Every FE spec is run for levels and Poisson so main and saturated can be
# shown side by side:
#   main       ADM2 x age + year x age (fails the lead placebo)
#   saturated  + ADM1 x year x age
#   statetrend + ADM1 x age linear trends
#   region     macro-region x year x age instead of year x age
# Checks (main and saturated): precip poly, unweighted levels, Tmax heat
# controls, Northeast only.
RUNS=()
for fe in main saturated statetrend region; do
  RUNS+=("--fe_spec=${fe} --outcome_model=levels")
  RUNS+=("--fe_spec=${fe} --outcome_model=poisson")
done
for fe in main saturated; do
  RUNS+=("--fe_spec=${fe} --outcome_model=levels --prcp_poly=true")
  RUNS+=("--fe_spec=${fe} --outcome_model=poisson --prcp_poly=true")
  RUNS+=("--fe_spec=${fe} --outcome_model=levels --weighted=false")
  RUNS+=("--fe_spec=${fe} --outcome_model=levels --temp=tmax")
  RUNS+=("--fe_spec=${fe} --outcome_model=poisson --temp=tmax")
  RUNS+=("--fe_spec=${fe} --outcome_model=levels --sample=northeast")
  RUNS+=("--fe_spec=${fe} --outcome_model=poisson --sample=northeast")
done

# Scripts source ../../../../0_utils/paths.R, so each runs from its own folder.
for run in "${RUNS[@]}"; do
  echo "=== ${run}"
  (cd "${DROUGHT}/02_regressions" && "${RSCRIPT}" 02_brazil_regs.R ${run})
  (cd "${DROUGHT}/03_run_outputs" && "${RSCRIPT}" 01_brazil_reg_outputs.R ${run})
done
