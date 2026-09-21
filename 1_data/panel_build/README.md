# Rainfall-Mortality Panel Build

This folder builds the rainfall-mortality analysis panel. It starts from the
old Carleton mortality panel, adds cleaned mortality data for the newer
countries, and then adds climate, income, urban, elevation, and density
covariates. The original Carleton panel is read but never overwritten.

Main outputs:

```text
combined_panel/new_mortality_panel.csv
combined_panel/new_mortality_panel_urban.csv
```

`new_mortality_panel.csv` is the base panel. `new_mortality_panel_urban.csv`
adds GHSL urban variables and is the file most regression scripts read. The
final export step also writes RDS and Stata copies of both panels.

Panel outputs live under:

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build
```

## Panel Admin IDs

`admin_id` is the final analysis admin unit used for panel merges and
regressions. The original `adm1_id`, `adm2_id`, and `adm3_id` columns are kept
where they exist.

For old Carleton-panel countries, ADM2 is the final analysis unit, and
`admin_id` combines `adm1_id` and `adm2_id`. The newly added countries already
come with an `admin_id` in their cleaned mortality files. `country_files.csv`
lists those cleaned country files and their year ranges.

Intermediate files are organized as:

```text
old_panel/       trimmed old panel
new_countries/  new-country mortality and climate files
combined_panel/ combined panel files
checks/         final panel check workbook
logs/           Slurm logs
```

## Build Order

### 1. Build the Mortality Panel

`01_trim_old_panel.R` trims the old Carleton ERA5-Land panel to the variables
needed here. It keeps mortality, old-panel income, and the ERA5-Land climate
variables already present in that panel, then puts the old admin IDs into the
shared panel admin ID format.

`02_prepare_new_countries.R` stacks the cleaned mortality files listed in
`country_files.csv`. This step is mortality only: climate, income, and other
covariates are added later.

`03_merge_climate.R` adds annual ERA5-Land precipitation and temperature
polynomial variables to the new-country mortality rows. Most new countries use
ADM2 ERA5-Land files. The Philippines uses ADM3. Country-specific ID columns
are padded where needed before matching to `admin_id`.

`04_merge_adm1_income.R` adds the older Carleton-style ADM1-year income
variables to the new countries. Income is matched by `iso`, `adm1_id`, and
`year`, so every analysis unit inside an ADM1 receives the same annual income
value. The fixed `gdppc_adm1_avg` and `loggdppc_adm1_avg` variables are the
2005-2014 ADM1 averages used for income classification.

`05_build_panel.R` appends the trimmed old panel and the new-country
mortality-climate-income panel. The result is the base combined CSV:

```text
combined_panel/new_mortality_panel.csv
```

### 2. Add Climate Measures

ERA5-Land is the main climate dataset. CHIRPS is added as an alternative
precipitation measure.

`06_add_chirps.R` adds `prcp_poly_1_CHIRPS` through `prcp_poly_5_CHIRPS`.
CHIRPS is ADM2 for most countries, ADM3 for the Philippines, and ADM1 for
Japan. India and Mexico use the existing panel admin IDs to recover the old
Carleton-style admin IDs.

`07_add_adm1_climate.R` adds ADM1 ERA5-Land climate for the new countries.
ERA5-Land is available below ADM1 for these countries, so the script averages
lower-level admin values to ADM1 using LandScan 2011 population weights. It
adds annual ADM1 temperature, precipitation, cooling degree days, and heating
degree days, plus long-run ADM1 averages over the available years.

`07b_add_admin_precip_exposure.R` adds long-run admin extreme-rain measures
from the file built by:

```text
1_data/climate_data/climate_aggregation_global/era5land_admin/panel/
03_admin_precip_exposure.py
```

These variables are based on population-weighted daily admin precipitation.
They measure the average annual number of days above 50, 100, 150, and
200 mm, the average annual maximum daily rain, and the average daily-rain p99.
Old-panel countries are matched through the ERA5-Land crosswalk, while new
countries use the admin ID stored in `region_id`.

`07c_add_wind_exposure.R` adds annual all-weather ERA5-Land wind variables:

```text
windmax_pop_annual
windmax_area_annual
winddays_17p5_pop_annual
winddays_17p5_area_annual
```

These are not tropical-cyclone track variables. They come from annual summaries
of ERA5-Land daily maximum wind. As with the extreme-rain measures, old-panel
countries use the ERA5-Land crosswalk and new countries use `region_id`.

`07d_add_daily_rain_wind_overlap.R` summarizes daily extreme-rain event files
to admin-year variables before adding them to the panel. The event files come
from:

```text
1_data/climate_data/climate_aggregation_global/era5land_admin/panel/
04_rain_wind_events.py
05_combine_rain_wind_events.py
```

The script counts daily rain events at 100, 200, and 300 mm, then counts how
many of those days also had high wind within one day. High wind is defined as
some population-weighted grid-cell exposure above 17.5 m/s. It also keeps the
wettest event in each admin-year and the same-day and plus/minus-one-day wind
around that event.

Common variables from this step include:

```text
rain_days_100_wind_pm1day
rain_days_200_wind_pm1day
share_rain_days_100_wind_pm1day
share_rain_days_200_wind_pm1day
max_rain_event_mm
max_wind_on_rain_event_pm1day
wind_on_max_rain_day
wind_pm1day_on_max_rain_day
```

Admin-years with no daily rain event at or above 100 mm get zero event counts.
Maxima and shares stay missing because no event occurred.

### 3. Add Other Covariates

`08_add_urban.R` creates the urban panel by adding GHSL variables:

```text
year_5s
ghsl_population
settlement_type
urban_share
```

GHSL is available every five years. Mortality years are matched to the nearest
five-year GHSL year, with years before 1975 assigned to 1975. Country matching
uses different ID rules for new countries, most old-panel countries, Japan, and
Europe.

`09_add_kummu_income.R` adds gridded Kummu income aggregated to the panel admin
units. Annual values merge by `iso`, `admin_id`, and `year`. The 2010-2024
profile variables merge by `iso` and `admin_id`. These variables stay separate
from the older ADM1 income variables added in `04_merge_adm1_income.R`.

`10_add_elevation.R` adds fixed FABDEM elevation measures by `iso` and
`admin_id`, including area-weighted median elevation, population-weighted
median elevation, and shares of area or LandScan 2011 population below low
elevation cutoffs.

`10b_add_pop_density.R` adds fixed population density measures by `iso` and
`admin_id`: mortality-panel population density, LandScan 2011 density,
population-weighted LandScan 2011 density, and population-weighted GHSL 2010
density.

### 4. Check and Export

`11_check_panel.R` writes the final check workbook:

```text
checks/panel_checks.xlsx
```

The useful sheets are `summary`, `countries`, `rows_by_age`,
`duplicate_rows`, `missing_by_country`, `deathrate_summary`,
`top_deathrates`, and `small_populations`.

The workbook is written under the project data folder:

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/checks/
```

`12_export_panel.R` writes RDS and Stata copies of the two CSV panels:

```text
combined_panel/new_mortality_panel.rds
combined_panel/new_mortality_panel.dta
combined_panel/new_mortality_panel_urban.rds
combined_panel/new_mortality_panel_urban.dta
```

RDS files keep the CSV variable names. A few long precipitation-exposure names
are shortened only in the Stata files because of Stata's variable-name limit.

## Running the Build

Create the log folder if it is missing:

```text
mkdir -p logs
```

Run the full panel build:

```text
sbatch run_panel_build.sbatch
```

Refresh only the final check workbook and RDS/Stata exports:

```text
sbatch run_checks_exports.sbatch
```
