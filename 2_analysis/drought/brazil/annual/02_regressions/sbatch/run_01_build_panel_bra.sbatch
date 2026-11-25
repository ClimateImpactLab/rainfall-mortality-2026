#!/bin/bash
#SBATCH --job-name=drought_panel_bra
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=01:00:00
#SBATCH --mem=48G
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs/%x_%j.err

set -euo pipefail

REPO="/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026"
RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
DROUGHT="${REPO}/2_analysis/drought/brazil/annual"
# PANEL: stable (default, 2000-2024) or old (1997-2010, to reproduce the
# earlier results)
PANEL="${PANEL:-stable}"
# PERIOD (stable panel only): 2000_2024 (default) or 1997_2010
PERIOD="${PERIOD:-2000_2024}"

mkdir -p "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_annual/logs"

# Brazil mortality + drought panel for the regs. Needs the yearly drought and
# SPI files from the 01_measures sbatch files.
#
cd "${DROUGHT}/02_regressions"
if [[ "${PANEL}" == "stable" ]]; then
  "${RSCRIPT}" 01b_build_brazil_panel_stable.R --write --period=${PERIOD}
else
  "${RSCRIPT}" 01_build_brazil_panel.R --write
fi
