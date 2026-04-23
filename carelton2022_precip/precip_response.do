*****************
*   INITIALIZE
*****************
* select dataset and output folder
loc reg_folder  "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data"
loc rf_folder   "/project/cil/home_dirs/nishkasharma/misc/rainfall_mortality/output/data"

* store ster and response function names in a local
local ster_name "`reg_folder'/1_estimation/1_ster/age_spec/Agespec_response_spec2.ster"
local rf_name   "`rf_folder'/precip_response_by_iso.csv"

* to see how much it takes the code to run
local start_time = clock("$S_DATE $S_TIME", "DMYhms")

*****************
* get adm0_code and age group code from mortality panel
*****************
use "`rf_folder'/adm0_code.dta", clear
// egen adm0_code = group(iso)
// duplicates drop adm0 iso adm0_code, force
// keep adm0 iso adm0_code
// /* levels of agegroup
//            0 total
//            1 0-4
//            2 5-64
//            3 65+
// */

* test on a small sample first
// keep if adm0_code <= 4
* store adm0_code in a local
levelsof adm0_code, local(countries)

* save country name, iso code, adm0 code to merge with predicted values later
tempfile country_lookup
save `country_lookup'

*****************
* load estimates once before the loop
*****************
est use `ster_name'

*****************
* create y_hat values
*****************
tempfile results

* initialise empty results file with the variables we want
clear
gen deathrate_w99 = .
gen iso_code = .
gen prcp_value = .
gen yhat_0_4 = .
gen lowerci_0_4 = .
gen upperci_0_4 = .
gen se_0_4 = .
gen yhat_5_64 = .
gen lowerci_5_64 = .
gen upperci_5_64 = .
gen se_5_64 = .
gen yhat_65_above = .
gen lowerci_65_above = .
gen upperci_65_above = .
gen se_65_above = .
save `results'


* loop over country and precip range
foreach iso_code in `countries' {
    di "Processing country `iso_code'..."
     forvalues row_values = 0(1)300 {

        * start from a single-row dataset for predictnl to work on
	clear
	set obs 1
	gen deathrate_w99 = .
	
	* tag this row with its country and precipitation value
        gen adm0_code   = `iso_code'
        gen prcp_value = `row_values'

        * predict response function for each age group
        * note: age group 1 (0-4) is the base category so we use _b directly
        capture predictnl yhat_0_4 = ///
	`row_values'   * _b[`iso_code'.adm0_code#1b.agegroup#c.prcp_poly_1_GMFD] + ///
	`row_values'^2 * _b[`iso_code'.adm0_code#1b.agegroup#c.prcp_poly_2_GMFD], ///
	ci(lowerci_0_4 upperci_0_4) se(se_0_4)

        capture predictnl yhat_5_64 = ///
	`row_values'   * _b[`iso_code'.adm0_code#2.agegroup#c.prcp_poly_1_GMFD] + ///
	`row_values'^2 * _b[`iso_code'.adm0_code#2.agegroup#c.prcp_poly_2_GMFD], ///
	ci(lowerci_5_64 upperci_5_64) se(se_5_64)

        capture predictnl yhat_65_above = ///
	`row_values'   * _b[`iso_code'.adm0_code#3.agegroup#c.prcp_poly_1_GMFD] + ///
	`row_values'^2 * _b[`iso_code'.adm0_code#3.agegroup#c.prcp_poly_2_GMFD], ///
	ci(lowerci_65_above upperci_65_above) se(se_65_above)
        
//         keep adm0_code prcp_value ///
//              yhat_0_4 lowerci_0_4 upperci_0_4 se_0_4 ///
//              yhat_5_64 lowerci_5_64 upperci_5_64 se_5_64 ///
//              yhat_65_above lowerci_65_above upperci_65_above se_65_above

        * append to results
        append using `results'
        save `results', replace
    }
}

*****************
* merge back iso labels and export
*****************
use `results', clear
merge m:1 adm0_code using `country_lookup', nogen keep(match master)
sort adm0_code prcp_value

export delimited "`rf_name'", replace

local end_time = clock("$S_DATE $S_TIME", "DMYhms")
local elapsed = (`end_time' - `start_time') / 60000
di "Elapsed time: `elapsed' minutes"




