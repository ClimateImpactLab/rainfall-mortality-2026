#!/bin/bash
#SBATCH --job-name=flow_regs_usa
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=06:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.err

set -euo pipefail

# Repo checkout of the user who submits the job (same rule as 0_utils/paths.R)
REPO="/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026"
# R environment of the other reg runners (has fixest and MetBrewer).
# Use another one with: RSCRIPT=/path/to/Rscript sbatch ...
RSCRIPT="${RSCRIPT:-/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript}"
FLOWS="${REPO}/2_analysis/flows"

mkdir -p "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs"

# USA flow runs, set up like the main precip regs (regressions/01_main_response.R):
# main and saturated FE, population weights and both wind controls by default.
# For each run the regs (02_usa_flow_regs.R), then its figures
# (03_run_outputs/01_usa_flow_reg_outputs.R). At the end, one Overleaf document
# with both runs (03_run_outputs/02_make_overleaf_doc.R).
#   levels   OLS on the winsorized death rate
#   poisson  Poisson on the winsorized death rate (fepois, as in the main regs)
RUNS=(
  "--outcome_model=levels"
  "--outcome_model=poisson"
)

# Scripts source ../../../0_utils/paths.R, so each runs from its own folder.

# Descriptive figures and the measures TeX, once: they do not depend on a run
(cd "${FLOWS}/03_run_outputs" && "${RSCRIPT}" 00_describe_flow_measures.R)

for run in "${RUNS[@]}"; do
  echo "=== ${run}"
  (cd "${FLOWS}/02_regressions" && "${RSCRIPT}" 02_usa_flow_regs.R ${run})
  (cd "${FLOWS}/03_run_outputs" && "${RSCRIPT}" 01_usa_flow_reg_outputs.R ${run})
done

# One Overleaf document with the measures, descriptives and both runs:
# output/data/flows/usa-annual/overleaf/
(cd "${FLOWS}/03_run_outputs" && "${RSCRIPT}" 02_make_overleaf_doc.R)
