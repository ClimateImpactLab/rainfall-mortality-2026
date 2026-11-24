#!/bin/bash
#SBATCH --job-name=panel_build
#SBATCH --partition=cil
#SBATCH --account=cil
#SBATCH --time=04:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

set -euo pipefail

# Full panel build. Writes to annual/panel_update/ (see paths.R).

cd /project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build

# Create the code-side log folder before opening this job's logs.
LOG_DIR="$PWD/logs"
mkdir -p "$LOG_DIR"
exec >"$LOG_DIR/panel_build_${SLURM_JOB_ID}.out" 2>"$LOG_DIR/panel_build_${SLURM_JOB_ID}.err"

R=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# 1. Save 01_panel_mortality.csv: mortality, population and geography only
$R scripts/1a_trim_old_panel.R
$R scripts/1b_prepare_new_countries.R
$R scripts/1c_combine_panels.R

# 2. Save 02_panel_climate.csv; leave 01 unchanged
$R scripts/2a_add_new_country_climate.R
$R scripts/2b_add_chirps.R
$R scripts/2c_add_adm1_climate.R
# Daily-rain diagnostics are separate from the regression climate terms.
# $R scripts/2d_add_precip_extremes.R
$R scripts/2e_add_wind.R
$R scripts/2f_add_rain_wind_overlap.R
$R scripts/2g_add_drought_terms.R

# 3. Save 03_panel_full.csv; leave 01 and 02 unchanged
$R scripts/3a_add_adm1_income.R
$R scripts/3b_add_kummu_income.R
$R scripts/3c_add_urban.R
$R scripts/3d_add_elevation.R
$R scripts/3e_add_pop_density.R
$R scripts/3f_add_ag_land.R

# 4. Check and export
$R scripts/4a_check_panel.R
$R scripts/4b_export_panel.R
