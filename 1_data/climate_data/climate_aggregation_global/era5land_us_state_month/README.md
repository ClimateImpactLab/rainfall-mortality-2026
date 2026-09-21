# ERA5-Land U.S. State-Month Climate

The scripts in this folder aggregate ERA5-Land wind and precipitation to the
[Young-Hsiang U.S. state-month panel](https://doi.org/10.1038/s41586-024-07945-5).

These files are used for our tropical cyclone confounding check. The state
shapefile comes from the Young-Hsiang/Census 2016 data. Wind is ERA5-Land
all-weather daily maximum wind, not tropical-cyclone-only wind.

The heavy raster and NetCDF steps are run through the sbatch files in
[jobs/](jobs/).

## Inputs

Raw ERA5-Land wind:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/wind_max/
```

Raw ERA5-Land precipitation:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/tp_total/
```

These scripts intentionally read raw wind and precipitation from the USA
regional raw folders above. This Young-Hsiang check keeps those source files
rather than switching to the global ERA5-Land raw folder.

Young-Hsiang/Census 2016 state shapefile:

```text
/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/raw/data/cb_2016_us_state_20m/cb_2016_us_state_20m.shp
```

Young-Hsiang state-month panel:

```text
/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/raw/data/DATA_hurricane_mortality_temp_month_state_19302015.dta
```

## Outputs

State weights:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/landscan2011/ERA5-LAND/USA_STATE_MONTH/
```

State-month climate:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/USA/state_month/
```

Main file names:

```text
era5land_usa_state_month_wind_YEAR.csv
era5land_usa_state_month_wind_1950_2015.csv
era5land_usa_state_month_precip_YEAR.csv
era5land_usa_state_month_precip_1950_2015.csv
```

Young-Hsiang panel with ERA5-Land climate added:

```text
/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed/young_hsiang_state_month_era5land_climate_1950_2015.csv
/project/cil/gcp/estimation/rainfall-mortality/external_data/young_hsiang_tc_mortality/processed/young_hsiang_state_month_era5land_climate_1950_2015.dta
```

Large outputs and logs are kept outside the repo.

## Folder Contents

```text
01_make_state_weights.py
02_aggregate_monthly_wind.py
03_aggregate_monthly_precip.py
04_combine_state_month.py
05_merge_young_hsiang_panel_climate.R
jobs/
```

The Python scripts reuse the ERA5-Land grid reader and CSV/check helpers from
[era5land_admin/common.py](../era5land_admin/common.py).

[jobs/](jobs/) contains the sbatch files used to run the heavy steps on RCC.
See the notes below.

## Scripts

### 01_make_state_weights.py

Builds fixed state-to-ERA5-Land-cell weights. The Young-Hsiang panel defines
the state sample, and the Young-Hsiang/Census 2016 shapefile supplies the state
polygons.

Population weights use LandScan 2011. Area weights use GPW 2010 land-area
points, not GPW population. These weights are reused for all years.

GPW stands for Gridded Population of the World. Here we use its land-area data,
not its population data. In this repo, the GPW land-area data are stored as a
parquet point table. Each point is the center of a small GPW grid cell, and the
`land_area` column gives the land area represented by that cell. We use the
point location to assign land area to a state polygon and to an ERA5-Land grid
cell. Then we sum land area by state and ERA5-Land cell, and normalize those
totals into area weights.

LandScan 2011 population raster:

```text
/project/cil/battuta_shares/gcp/social/sources/Landscan2011/RasterGISbinary/lspop2011.flt
```

GPW land-area point table:

```text
/project/cil/gcp/temp_data/gpw_2010_land_area_points
```

### 02_aggregate_monthly_wind.py

Aggregates one year of daily ERA5-Land `wind_max` to state-month values.

For each state-month, take the monthly maximum in each grid cell first, then
average those grid-cell maxima to the state. This max-first order is
intentional because it preserves local wind extremes before spatial averaging.

### 03_aggregate_monthly_precip.py

Aggregates one year of daily ERA5-Land `tp_total` to state-month values.

For each day, compute precipitation powers in each grid cell first, then
average to the state. Monthly values sum those daily state values. This keeps
rainfall extremes and nonlinearities at the grid-cell level before state
aggregation.

### 04_combine_state_month.py

Stacks yearly state-month wind or precipitation files into one CSV for the
requested year range.

### 05_merge_young_hsiang_panel_climate.R

Merges the combined ERA5-Land wind and precipitation files into the
Young-Hsiang state-month mortality panel. It writes CSV and Stata copies of the
processed panel.

## Usual Run Order

Run these commands from the climate aggregation folder:

```bash
cd /path/to/rainfall-mortality-2026/1_data/climate_data/climate_aggregation_global
```

Build weights once:

```bash
sbatch era5land_us_state_month/jobs/01_state_weights.sbatch
```

Aggregate monthly wind, one year per array task:

```bash
sbatch --array=1950-2015%6 \
  era5land_us_state_month/jobs/02_state_month_wind.sbatch
```

Aggregate monthly precipitation, one year per array task:

```bash
sbatch --array=1950-2015%6 \
  era5land_us_state_month/jobs/03_state_month_precip.sbatch
```

Combine yearly wind files:

```bash
/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python \
  era5land_us_state_month/04_combine_state_month.py \
  --variable wind \
  --first-year 1950 --last-year 2015
```

Combine yearly precipitation files:

```bash
/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python \
  era5land_us_state_month/04_combine_state_month.py \
  --variable precip \
  --first-year 1950 --last-year 2015
```

Merge wind and precipitation into the Young-Hsiang panel:

```bash
/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript \
  era5land_us_state_month/05_merge_young_hsiang_panel_climate.R \
  --first-year 1950 --last-year 2015
```

Pass `--overwrite` only when replacing existing outputs.

## Slurm Jobs

The sbatch files in [jobs/](jobs/) cover the three heavy steps:

```text
jobs/01_state_weights.sbatch
jobs/02_state_month_wind.sbatch
jobs/03_state_month_precip.sbatch
```

[01_state_weights.sbatch](jobs/01_state_weights.sbatch) builds the fixed U.S.
state-to-ERA5-Land-cell weights. Run it once unless the geography, grid, or
weight inputs change.

[02_state_month_wind.sbatch](jobs/02_state_month_wind.sbatch) and
[03_state_month_precip.sbatch](jobs/03_state_month_precip.sbatch) are year
arrays. Each task reads one annual daily NetCDF file and writes one state-month
CSV.

Logs are written outside the repo:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data/logs/era5land_us_state_month/
```
