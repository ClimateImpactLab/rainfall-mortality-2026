#!/bin/bash
#SBATCH --job-name=drought_monthly
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/drought/brazil_monthly/logs/%x_%j.err
#SBATCH --time=03:00:00
#SBATCH --mem=48G
#SBATCH --cpus-per-task=4

set -euo pipefail

RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/2_analysis/drought/brazil/monthly"

# Brazil monthly, 2000-2024 (default) or 1997-2010 (PERIOD=1997_2010). Needs the monthly drought
# measures from 01_build_monthly_measures.R --write.
#   02: regression panel (drought lags and leads)
#   03: Poisson regs, main, saturated and state x year-month FE
PERIOD="${PERIOD:-2000_2024}"
"${RSCRIPT}" 02_build_panel.R --period=${PERIOD} --write

for fe in main saturated statemonth; do
  echo "=== --fe_spec=${fe}"
  "${RSCRIPT}" 03_monthly_regs.R --period=${PERIOD} --fe_spec=${fe}
done
