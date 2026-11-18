#!/bin/bash
#SBATCH --job-name=cv_precip_flow_usa
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=00:15:00
#SBATCH --mem=16G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs/%x_%j.err

set -euo pipefail


REPO="/project/cil/home_dirs/${USER}/repos/rainfall-mortality-2026"
RSCRIPT="${RSCRIPT:-/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript}"

mkdir -p "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/flows/usa_annual/logs"

cd "${REPO}/2_analysis/flows/04_cross_validation"
"${RSCRIPT}" 01_usa_cv_residualize.R
"${RSCRIPT}" 02_usa_cv_precip_vs_flow.R
