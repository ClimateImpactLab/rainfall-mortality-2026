# ERA5-Land Admin Aggregation

The scripts in this folder aggregate ERA5-Land grid-cell data to the mortality
panel admin units.

```text
/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global
```

Aggregated outputs are written under:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL
```

It is used to:

- build admin-to-ERA5-Land-cell weights
- aggregate daily precipitation and temperature to admin units
- combine daily precipitation and temperature into monthly and annual admin-level files
- build annual all-weather wind exposure from `wind_max` files
- aggregate daily windspeed from `wind_max` files to check overlapping high-wind and heavy-rain days


The heavy raster and NetCDF steps are run through the sbatch files in `jobs/`.

## Folder Contents

```text
settings.py
common.py
wind_common.py
aggregation_scripts/
panel/
cell_fallback/
diagnostics/
jobs/
```

`settings.py` defines the country settings: shapefiles, ID columns, year ranges,
and the raw ERA5-Land path.

`common.py` defines functions used across scripts for checks, CSV writing,
admin IDs, and ERA5-Land grid reading.

`wind_common.py` defines functions used by the annual wind, daily wind, and
rain-event wind scripts. It reads `wind_max` files and handles the wind-only
small-island fallback.

`aggregation_scripts/` contains the main scripts for weights, precipitation,
temperature, and wind. The scripts are described below.

`cell_fallback/` handles small coastal or island admin units whose assigned
ERA5-Land cells are missing in the raw climate files. See
[cell_fallback/README.md](cell_fallback/README.md).

`panel/` prepares ERA5-Land files for the old panel used for the Carleton
countries. See [panel/README.md](panel/README.md).

`jobs/` contains the sbatch files used to run the scripts on RCC. See
[jobs/README.md](jobs/README.md).


## Output Location

Generated files are written here:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data
```

Keep large outputs outside the repo.

## Aggregation Scripts

```text
aggregation_scripts/01_make_weights.py
aggregation_scripts/02_aggregate_prcp_temp.py
aggregation_scripts/03_check_prcp_temp.py
aggregation_scripts/04_combine_prcp_temp.py
aggregation_scripts/05_aggregate_annual_wind.py
aggregation_scripts/06_combine_annual_wind.py
aggregation_scripts/07_aggregate_daily_wind.py
```

The matching sbatch files are in `jobs/`.

### 01_make_weights.py

Builds fixed admin-to-ERA5-Land-cell weights. Population weights use LandScan
2011. Area weights use GPW 2010 land-area points, not GPW population. These
weights are reused for all years.

GPW stands for Gridded Population of the World. Here we use its land-area data,
not its population data. In this repo, the GPW land-area data are stored as a
parquet point table. Each point is the center of a small GPW grid cell, and the
`land_area` column gives the land area represented by that cell. We use the
point location to assign land area to an admin polygon and to an ERA5-Land grid
cell. Then we sum land area by admin unit and ERA5-Land cell, and normalize
those totals into area weights.

LandScan 2011 population raster:

```text
/project/cil/battuta_shares/gcp/social/sources/Landscan2011/RasterGISbinary/lspop2011.flt
```

GPW land-area point table:

```text
/project/cil/gcp/temp_data/gpw_2010_land_area_points
```

ERA5-Land admin weights are written here:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/landscan2011/ERA5-LAND-GLOBAL/<COUNTRY>/
```

Weights store ERA5-Land cells by row and column number. These weights are tied
to the full global grid used by the raw files in this folder.

### 02_aggregate_prcp_temp.py

Aggregates daily ERA5-Land precipitation, mean temperature, and maximum
temperature to admin units. The raw files are monthly global NetCDF files. The
script reads one month at a time and only reads the rows and columns used by
the country's weights. It writes daily, monthly, and annual files.

Precipitation powers are calculated at the grid-cell level before aggregation:

```text
daily grid-cell precip -> precip, precip^2, ..., precip^5 -> admin average
```

This is not the same as averaging precipitation first and then taking powers.
This keeps more information about rainfall extremes and nonlinearities inside
the admin unit before the values are averaged to the admin level.

### 03_check_prcp_temp.py

Checks one country-year after precipitation and temperature aggregation. It
checks row counts, output files, missing climate coverage, and basic value
ranges.

### 04_combine_prcp_temp.py

Combines the annual precipitation and temperature files after country-years
have been aggregated.

### 05_aggregate_annual_wind.py

Creates annual all-weather wind variables from `wind_max` files. The
main maximum is calculated at the grid-cell level first, then averaged to the
admin unit.

### 06_combine_annual_wind.py

Combines annual all-weather wind files after country-years have been
aggregated.

### 07_aggregate_daily_wind.py

Creates daily admin-level all-weather wind files. These are used for checks
that compare wind and rainfall on the same days.

## Usual Run Order

The commands below use Brazil as an example. Replace `BRA` and the year range
with the country and years you need.

Start here:

```bash
cd /path/to/rainfall-mortality-2026/1_data/climate_data/climate_aggregation_global
```

Build weights:

The weight job has two steps.

First, split the country's shapefile into chunks and build weights for each
chunk. These are chunks of admin polygons, not years (we use the same weights for every year).
For this Brazil example, `20` means the Brazil admin units are split into 20 chunks, and `%10` means at
most 10 chunks run at the same time. This keeps the spatial weight work smaller
and faster.

```bash
sbatch --array=0-19%10 \
  era5land_admin/jobs/aggregation/01_weights.sbatch BRA 20
```

After those 20 chunks finish, combine them into the final weight files:

```bash
sbatch era5land_admin/jobs/aggregation/01_combine_weights.sbatch BRA 20
```

Aggregate daily, monthly, and annual precipitation and temperature files:

```bash
sbatch --array=1950-2025%10 \
  era5land_admin/jobs/aggregation/02_prcp_temp.sbatch BRA
```

Check one country-year:

```bash
sbatch era5land_admin/jobs/aggregation/03_check_prcp_temp.sbatch BRA 2020
```

Combine annual climate files:

```bash
sbatch era5land_admin/jobs/aggregation/04_combine_prcp_temp.sbatch
```

Aggregate annual wind:

```bash
sbatch --array=1950-2025%2 \
  era5land_admin/jobs/aggregation/05_annual_wind.sbatch BRA
```

Combine annual wind:

```bash
sbatch era5land_admin/jobs/aggregation/06_combine_annual_wind.sbatch
```

## Output Files

Weights:

```text
weights/landscan2011/ERA5-LAND-GLOBAL/<COUNTRY>/
```

Country-year climate:

```text
ERA5-LAND-GLOBAL/<COUNTRY>/daily/
ERA5-LAND-GLOBAL/<COUNTRY>/monthly/
ERA5-LAND-GLOBAL/<COUNTRY>/annual/
```

Combined files:

```text
ERA5-LAND-GLOBAL/combined/
```

Logs:

```text
logs/era5land_admin/
```

## Notes

Cell fallback has been applied only where the replacement cell is close enough
to be defensible. The remaining missing island/territory units are documented
in `cell_fallback/README.md`. We could revisit them later if those units matter,
but they are not used in the final analysis sample.
