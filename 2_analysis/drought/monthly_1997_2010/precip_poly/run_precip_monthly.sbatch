#!/bin/bash
#SBATCH --job-name=precip_monthly_1997_2010
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --output=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_monthly/logs/%x_%j.out
#SBATCH --error=/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/precip_monthly/logs/%x_%j.err
#SBATCH --time=06:00:00
#SBATCH --mem=96G
#SBATCH --cpus-per-task=8

set -euo pipefail

RSCRIPT="/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript"
cd "/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/2_analysis/drought/monthly_1997_2010/precip_poly"

# Brazil monthly, precip only, 1997-2010.
#   01: panel with rainfall terms, 12 lags and 6 leads
#   02: Poisson regs, main and saturated FE, temp with and without lags
#   03: figures and tables
# Pass --skip_build to reuse the panel.
if [[ "${1:-}" != "--skip_build" ]]; then
  "${RSCRIPT}" 01_build_panel.R
fi

for fe in saturated main; do
  for temp in lags current; do
    echo "=== --fe_spec=${fe} --temp=${temp}"
    "${RSCRIPT}" 02_regs.R --fe_spec=${fe} --temp=${temp}
  done
done

"${RSCRIPT}" 03_figures.R
