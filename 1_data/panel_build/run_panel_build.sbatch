#!/bin/bash
#SBATCH --job-name=panel_build
#SBATCH --partition=cil
#SBATCH --account=cil
#SBATCH --time=04:00:00
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build/logs/panel_build_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build/logs/panel_build_%j.err

set -euo pipefail

# Run the full panel build.

cd /project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/panel_build

R=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

# Prepare the old panel and new-country mortality rows.
$R scripts/01_trim_old_panel.R
$R scripts/02_prepare_new_countries.R

# Add ERA5-Land climate and ADM1 income to the new countries.
$R scripts/03_merge_climate.R
$R scripts/04_merge_adm1_income.R

# Append old and new countries, then add other climate variables.
$R scripts/05_build_panel.R
$R scripts/06_add_chirps.R
$R scripts/07_add_adm1_climate.R
$R scripts/07b_add_admin_precip_exposure.R
$R scripts/07c_add_wind_exposure.R
$R scripts/07d_add_daily_rain_wind_overlap.R

# Add urban, income, elevation, and density variables.
$R scripts/08_add_urban.R
$R scripts/09_add_kummu_income.R
$R scripts/10_add_elevation.R
$R scripts/10b_add_pop_density.R

# Check the final CSV panel and write RDS/Stata copies.
$R scripts/11_check_panel.R
$R scripts/12_export_panel.R
