#!/bin/bash
#SBATCH --job-name=phl_mortality
#SBATCH --account=cil
#SBATCH --partition=cil
#SBATCH --time=08:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=60G
#SBATCH --output=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/mortality_data/1_cleaning/Death_Rates/PHL/logs/phl_mortality_%j.out
#SBATCH --error=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/mortality_data/1_cleaning/Death_Rates/PHL/logs/phl_mortality_%j.err

set -eo pipefail

PHL_DIR=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026/1_data/mortality_data/1_cleaning/Death_Rates/PHL
RSCRIPT=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript

export RAINFALL_MORTALITY_REPO=/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026
export PATH=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin:$PATH

mkdir -p "$PHL_DIR/logs"
cd "$PHL_DIR"

echo "01_Admin_Codes/01_metadata_geocode_crosswalk.R"
"$RSCRIPT" 01_Admin_Codes/01_metadata_geocode_crosswalk.R

echo "01_Admin_Codes/02_psgc_geocodes_clean.R"
"$RSCRIPT" 01_Admin_Codes/02_psgc_geocodes_clean.R

echo "01_Admin_Codes/03_psgc_shp_crosswalk.R"
"$RSCRIPT" 01_Admin_Codes/03_psgc_shp_crosswalk.R

echo "01_Admin_Codes/04_metadata_psgc_shp_crosswalk.R"
"$RSCRIPT" 01_Admin_Codes/04_metadata_psgc_shp_crosswalk.R

echo "02_Population/01_clean_population_census_years.R"
"$RSCRIPT" 02_Population/01_clean_population_census_years.R

echo "02_Population/02_align_adm3_boundaries.R"
"$RSCRIPT" 02_Population/02_align_adm3_boundaries.R

echo "02_Population/03_interpolate_population.R"
"$RSCRIPT" 02_Population/03_interpolate_population.R

echo "03_Mortality/01_clean_mortality_records.R"
"$RSCRIPT" 03_Mortality/01_clean_mortality_records.R

echo "03_Mortality/03_align_mortality_boundaries.R"
"$RSCRIPT" 03_Mortality/03_align_mortality_boundaries.R

echo "03_Mortality/02_build_mortality_rates.R"
"$RSCRIPT" 03_Mortality/02_build_mortality_rates.R

echo "04_Descriptives/01_prepare_cause_summary.R"
"$RSCRIPT" 04_Descriptives/01_prepare_cause_summary.R

echo "04_Descriptives/02_check_original_vs_aligned_low_rates.R"
"$RSCRIPT" 04_Descriptives/02_check_original_vs_aligned_low_rates.R

echo "04_Descriptives/03_check_barmm_low_rates.R"
"$RSCRIPT" 04_Descriptives/03_check_barmm_low_rates.R

echo "03_Mortality/04_build_final_panel.R"
"$RSCRIPT" 03_Mortality/04_build_final_panel.R

echo "Done"
