* -----------------------------
* 02_add_era5land_to_old_panel.do
*
* Add annual ERA5-Land precipitation and temperature variables to the old global
* mortality panel through 2010.
*
* Inputs:
* - old global mortality panel
* - old-panel annual ERA5-Land climate file
*
* Outputs:
* - old global mortality panel copy with ERA5-Land variables
* - merge log
*
* The original mortality panel is left untouched. This file writes a new copy
* with the ERA5-Land variables added.
* -----------------------------

clear all
set more off
set varabbrev off

* -----------------------------
* Paths
* -----------------------------

local source "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final/global_mortality_panel.dta"
local climate "/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/combined/era5land_global_panel_annual.dta"
local output "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final/global_mortality_panel_updated_era5.dta"

* The sbatch runs this do-file from the era5land_admin folder.
* Keep the Stata log with the other ERA5-Land logs, not in the code folder.
capture mkdir "../logs"
capture mkdir "../logs/era5land_admin"
local log_file "../logs/era5land_admin/add_era5land_to_old_panel.log"

capture log close
log using "`log_file'", replace text

* -----------------------------
* Read old panel
* -----------------------------

* Keep the old Carleton-style panel period used by this ERA5-Land merge.
use "`source'", clear
keep if year <= 2010

unab original_variables : _all
generate long __era5_original_order = _n

tempfile original_through_2010
save "`original_through_2010'"

* -----------------------------
* Merge annual climate
* -----------------------------

* Mortality rows repeat by age group. The climate file is one row per
* admin-year, so every age group gets the same admin-year climate value.
merge m:1 iso adm1_id adm2_id year using "`climate'", ///
    keep(master match) generate(__merge_era5)

count if __merge_era5 == 3
display "MATCHED_ROWS=" r(N)
count if __merge_era5 == 1
display "UNMATCHED_ROWS=" r(N)

* Check that the merge did not alter the original mortality variables or rows.
sort __era5_original_order
cf `original_variables' using "`original_through_2010'", all

* -----------------------------
* Check ERA5-Land variables
* -----------------------------

* The old-panel copy keeps only population-weighted annual variables.
forvalues power = 1/5 {
    label variable prcp_poly_`power'_ERA5LAND ///
        "Annual sum of population-weighted daily precipitation^`power' - ERA5-Land"
    label variable tavg_poly_`power'_ERA5LAND ///
        "Annual sum of population-weighted daily mean temperature^`power' - ERA5-Land"
    label variable tmax_poly_`power'_ERA5LAND ///
        "Annual sum of population-weighted daily maximum temperature^`power' - ERA5-Land"
}

misstable summarize prcp_poly_1_ERA5LAND tavg_poly_1_ERA5LAND ///
    tmax_poly_1_ERA5LAND

* -----------------------------
* Write old-panel copy
* -----------------------------

drop __era5_original_order __merge_era5
compress
save "`output'", replace

display "FINAL_ROWS=" _N
display "WROTE_PANEL=`output'"

log close
exit, clear
