# Rainfall-Mortality Panel Build

This folder builds the rainfall-mortality panel from the cleaned country
mortality files and adds the covariates used in the analysis.

The old Carleton panel is read but not overwritten. New panel files are written
under:

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build
```

`country_files.csv` lists the cleaned mortality files for the newly added
countries.

## Folder structure

```text
scripts/   panel-build scripts
logs/      Slurm logs
```

Panel files are written here:

```text
old_panel/       trimmed old panel
new_countries/   new-country intermediate files
combined_panel/  combined mortality panels
checks/          final panel check from 11_check_panel.R
```

## Main outputs

```text
panel_build/combined_panel/new_mortality_panel.csv
panel_build/combined_panel/new_mortality_panel_urban.csv
```

`new_mortality_panel.csv` is the base panel.

`new_mortality_panel_urban.csv` adds the GHSL urban variables:

```text
year_5s
ghsl_population
settlement_type
urban_share
```

The final export step also writes RDS and Stata copies of both panels.

## Run order

### 01_trim_old_panel.R

Reads the old Carleton mortality panel and keeps the variables needed for the
new panel.

It writes a trimmed old-panel file under:

```text
panel_build/old_panel/
```

For old-panel countries, ADM2 is the final analysis unit
`admin_id` combines `adm1_id` and `adm2_id`.

### 02_prepare_new_countries.R

Combines the cleaned mortality files listed in `country_files.csv`

`admin_id` and `admin_name` identify the final analysis unit.
ADM1, ADM2, and ADM3 variables are also kept where those levels are available.

This step contains mortality only.
Climate, income, and other covariates are added later.

It writes the first new-country panel under:

```text
panel_build/new_countries/
```

### 03_merge_climate.R

Adds annual ERA5-Land climate variables to the new-country mortality panel by
`iso`, `admin_id`, and `year`.

Most countries use ADM2 ERA5-Land files. The Philippines uses ADM3.

This step updates the new-country panel under:

```text
panel_build/new_countries/
```

### 04_merge_adm1_income.R

Adds the older ADM1-year income variables to the new-country mortality-climate
panel by `iso`, `adm1_id`, and `year`.

Income is matched at the ADM1 or income-region level, so admin units within the
same ADM1 receive the same annual income value.

The fixed `gdppc_adm1_avg` and `loggdppc_adm1_avg` variables are 2005-2014 ADM1
averages used for income classification.

This step updates the new-country panel under:

```text
panel_build/new_countries/
```

### 05_build_panel.R

Combines the trimmed old panel with the new-country panel.

It writes:

```text
panel_build/combined_panel/new_mortality_panel.csv
```

### 06_add_chirps.R

Adds the five CHIRPS precipitation polynomial variables:

```text
prcp_poly_1_CHIRPS
prcp_poly_2_CHIRPS
prcp_poly_3_CHIRPS
prcp_poly_4_CHIRPS
prcp_poly_5_CHIRPS
```

ERA5-Land remains the main climate dataset.
CHIRPS is kept as an additional precipitation measure.

This step updates:

```text
panel_build/combined_panel/new_mortality_panel.csv
```

### 07_add_adm1_climate.R

Adds ADM1 ERA5-Land climate variables for the new countries:

```text
tavg_ERA5LAND_adm1
prcp_ERA5LAND_adm1
tmax_cdd_20C_ERA5LAND_adm1
tmax_hdd_20C_ERA5LAND_adm1
lr_tavg_ERA5LAND_adm1_avg
lr_prcp_ERA5LAND_adm1_avg
lr_cdd_20C_ERA5LAND_adm1_avg
lr_hdd_20C_ERA5LAND_adm1_avg
```

ERA5-Land is available at ADM2 for AUS, COL, ECU, KOR, and PER, and at ADM3
for PHL.
These lower-level values are averaged to ADM1 using LandScan 2011
population weights.

The long-run variables are averages over the years available for each country,
matching the approach used for the old panel.

This step updates:

```text
panel_build/combined_panel/new_mortality_panel.csv
```

### 07b_add_admin_precip_exposure.R

Adds static admin-level ERA5-Land extreme precipitation variables:

```text
prcp_pop_days_gt50_ERA5LAND_admin_avg
prcp_pop_days_gt100_ERA5LAND_admin_avg
prcp_pop_days_gt150_ERA5LAND_admin_avg
prcp_pop_days_gt200_ERA5LAND_admin_avg
prcp_pop_annual_max_ERA5LAND_admin_avg
prcp_pop_p99_ERA5LAND_admin_avg
precip_exposure_years
precip_exposure_days_observed
```

These are built from population-weighted daily precipitation in:

```text
1_data/climate_data/climate_aggregation/scripts/era5land_admin/panel/
04_build_admin_precip_exposure.py
```

The days-above-threshold variables are average annual counts of days above 50,
100, 150, and 200 mm/day.
The annual maximum and daily p99 measures are also averaged over the available
years.

This step updates `new_mortality_panel.csv`. If the urban panel already exists,
it updates that too.

### 07c_add_wind_exposure.R

Adds annual ERA5-Land wind variables:

```text
windmax_pop_annual
windmax_area_annual
winddays_17p5_pop_annual
winddays_17p5_area_annual
```

The wind file is built from daily `wind_max` in:

```text
1_data/climate_data/climate_aggregation/scripts/era5land_admin/
aggregation_scripts/07_combine_wind_exposure.py
```

The merge uses `iso`, `admin_id`, and `year`

This step updates `new_mortality_panel.csv`. If the urban panel already exists,
it updates that too. 

### 08_add_urban.R

Creates the urban panel by adding GHSL variables to the base panel:

```text
year_5s
ghsl_population
settlement_type
urban_share
```

GHSL is available every five years. 
Mortality years are matched to the nearest five-year GHSL year, with years
before 1975 assigned to 1975. 

It writes:

```text
panel_build/combined_panel/new_mortality_panel_urban.csv
```

### 09_add_kummu_income.R

Adds Kummu admin-level income variables to both the base and urban panels. 

Annual Kummu income merges by `iso`, `admin_id`, and `year`
The 2010-2024 profile variables are fixed within admin unit and merge by `iso`
and `admin_id`

These variables are kept separately from the older ADM1 income variables.

This step updates both combined panel CSVs.

### 10_add_elevation.R

Adds the FABDEM elevation variables:

```text
elev_median_m
share_area_elev_lt_10m
elev_pop_median_m
share_pop_elev_lt_5m
share_pop_elev_lt_10m
share_pop_elev_lt_20m
```

Elevation is fixed over time and merges by `iso` and `admin_id`.

This step updates both combined panel CSVs.

### 10b_add_pop_density.R

Adds the population density variables:

```text
panel_pop_density
landscan2011_pop_density
landscan2011_pop_pop_density
ghsl2010_pop_pop_density
```

Population density is fixed over time and merges by `iso` and `admin_id`.

This step updates both combined panel CSVs.

### 11_check_panel.R

Runs the final checks on the combined CSV panel.

The workbook includes:

```text
summary
countries
rows_by_age
duplicate_rows
missing_by_country
deathrate_summary
top_deathrates
small_populations
```

It writes:

```text
checks/panel_checks.xlsx
```

This file is written under the project data folder, not in the repo:

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/checks/
```

### 12_export_panel.R

Exports both final CSV panels as RDS and Stata files.

The RDS files keep the panel variable names unchanged. 
A small number of long variable names are shortened in the Stata files because
Stata has a variable-name length limit.

It writes:

```text
panel_build/combined_panel/new_mortality_panel.rds
panel_build/combined_panel/new_mortality_panel.dta
panel_build/combined_panel/new_mortality_panel_urban.rds
panel_build/combined_panel/new_mortality_panel_urban.dta
```

## Checks

Most scripts only stop when something would clearly break the panel: a missing
input file, duplicated merge rows, or a merge that changes the number of
mortality rows

`11_check_panel.R` writes the detailed check workbook at the end:

```text
/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/checks/panel_checks.xlsx
```

## Slurm scripts

The sbatch files write Slurm output under `logs/`.
That folder is ignored by git, so create it before submitting if it is missing:

```text
mkdir -p logs
```

Rebuild the full panel:

```text
run_panel_build.sbatch
```

Refresh only the final checks and RDS/Stata exports:

```text
run_checks_exports.sbatch
```

## Notes

- `admin_id` identifies the final analysis unit
- `adm1_id`, `adm2_id`, and `adm3_id` keep the original administrative IDs for
  the levels available in each country
- Kummu income is separate from the older ADM1 income variables
- Elevation and population density are fixed over time and merge by `iso` and `admin_id`
- ERA5-Land is the main climate dataset, CHIRPS is kept as an additional
  precip measure for robustness checks
