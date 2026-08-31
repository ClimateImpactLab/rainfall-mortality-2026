# Young-Hsiang Panel With ERA5-Land Wind

This note documents the Young-Hsiang state-month mortality panel with ERA5-Land wind and precipitation added for 1950-2015.

## Main Files

Processed data folder:

- `/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed/`

Files:

- `young_hsiang_state_month_era5land_wind_1950_2015.csv`
- `young_hsiang_state_month_era5land_wind_1950_2015.dta`
- `checks/era5land_vs_young_hsiang_wind_checks.xlsx`

The wind files now also include ERA5-Land precipitation.

The panel keeps the original Young-Hsiang years, 1930-2015. ERA5-Land wind and precipitation start in 1950, so rows before 1950 have missing ERA5-Land wind and precipitation.

## External Sources

Young-Hsiang data:

- Zenodo record: https://zenodo.org/records/11662454
- DOI: https://doi.org/10.5281/zenodo.11662454
- `data.zip`: https://zenodo.org/api/records/11662454/files/data.zip/content
- `output.zip`: https://zenodo.org/api/records/11662454/files/output.zip/content
- `ReadMe.txt`: https://zenodo.org/api/records/11662454/files/ReadMe.txt/content

Young-Hsiang code:

- GitHub: https://github.com/Global-Policy-Lab/young_hsiang_tc_mortality

Young-Hsiang files used here:

- `data/DATA_hurricane_mortality_temp_month_state_19302015.dta`
- `data/cb_2016_us_state_20m/cb_2016_us_state_20m.shp`

ERA5-Land raw windspeed (raster) used here:

- `/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/wind_max/`

ERA5-Land raw precipitation (raster) used here:

- `/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/tp_total/`

## How Wind and Precipitation Were Added

Wind and precipitation were merged by:

- `stfips`
- `year`
- `month`

`stfips` is the numeric U.S. state FIPS code.
The state polygons are the Census state shapes included in the Young-Hsiang data.
The output keeps the 36 states in their panel.

The ERA5-Land state-month files are:

- `/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/USA/state_month/era5land_usa_state_month_wind_1950_2015.csv`
- `/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/USA/state_month/era5land_usa_state_month_precip_1950_2015.csv`

State-grid weights are here:

- `/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/landscan2011/ERA5-LAND/USA_STATE_MONTH/era5land_usa_state_month_admins.csv`
- `/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/landscan2011/ERA5-LAND/USA_STATE_MONTH/era5land_usa_state_month_weights_landscan2011.csv`

## Added Wind Variables

- `windmax_pop_month`: population-weighted mean of grid-cell monthly maximum daily wind speed
- `windmax_area_month`: area-weighted mean of grid-cell monthly maximum daily wind speed

Units are meters per second.

Aggregation:

`daily grid-cell wind -> grid-cell monthly max -> state weighted mean`

## Added Precipitation Variables

- `prcp_pop_p1` through `prcp_pop_p5`: population-weighted monthly sums of daily grid-cell precipitation powers
- `prcp_area_p1` through `prcp_area_p5`: area-weighted monthly sums of daily grid-cell precipitation powers

Units for `prcp_*_p1` are millimeters. Higher powers are the same daily
precipitation values raised to powers 2 through 5 before aggregation.

Aggregation:

`daily grid-cell precipitation powers -> daily state weighted mean -> monthly sum`

## Coverage

For 1950-2015:

- states: 36
- rows: 28,512
- rows with ERA5-Land wind: 28,512
- missing ERA5-Land wind rows: 0
- rows with ERA5-Land precipitation: 28,512
- missing ERA5-Land precipitation rows: 0

## Check Workbook

The check workbook is:

- `/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed/checks/era5land_vs_young_hsiang_wind_checks.xlsx`

The workbook is created by:

- `2_analysis/wind_tc_validation/01_compare_young_hsiang_era5land_wind.R`

It compares Young and Hsiang's `maxs` variable with our area-weighted ERA5-Land wind variable, `windmax_area_month`.

The workbook has:

- `coverage`: row counts and missing wind counts
- `summary`: basic distribution and correlation checks
- `maxs_bins`: ERA5-Land wind by bins of Young-Hsiang `maxs`
- `top_young_hsiang_maxs`: months with the highest Young-Hsiang `maxs`
- `top_era5land_wind`: months with the highest ERA5-Land area-weighted wind

Main takeaway:

- In Young-Hsiang TC months, ERA5-Land area-weighted wind is in the same broad range as `maxs` through the middle of the distribution.
- The variables diverge in the upper tail. ERA5-Land does not reproduce the very high `maxs` values in the strongest TC months.
- This is consistent with ERA5-Land wind being useful as a broad wind check, but maybe not a perfect replacement measure for TC exposure. 


