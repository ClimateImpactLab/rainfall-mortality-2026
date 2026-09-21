* -----------------------------
* 00_export_panel_ids.do
*
* Export admin-year ids from the old global mortality panel.
*
* Inputs:
* - old global mortality panel
*
* Outputs:
* - distinct iso x adm1_id x adm2_id x year ids through 2010
*
* Geography:
* - old panel admin units
*
* This id file is used only to match ERA5-Land admin regions to the old panel.
* -----------------------------

clear all
set more off
set varabbrev off

* -----------------------------
* Paths
* -----------------------------

local source "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final/global_mortality_panel.dta"
local output "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/combined/global_panel_admin_year_ids.csv"

* The sbatch runs this do-file from the era5land_admin folder.
* Keep the Stata log with the other ERA5-Land logs, not in the code folder.
capture mkdir "../logs"
capture mkdir "../logs/era5land_admin"
local log_file "../logs/era5land_admin/export_panel_ids.log"

capture log close
log using "`log_file'", replace text

* -----------------------------
* Export ids
* -----------------------------

* The old panel is through 2010. Keep only the admin unit and year variables needed
* for the climate crosswalk
use "`source'", clear
keep if year <= 2010
keep iso adm1_id adm2_id year
duplicates drop
sort iso adm1_id adm2_id year

export delimited using "`output'", replace
display "ID_ROWS=" _N
display "WROTE_IDS=`output'"

log close
exit, clear
