# CHIRPS Admin Aggregation

The scripts in this folder aggregate CHIRPS daily precipitation to the mortality
panel admin units.

CHIRPS is used as another precipitation source for sensitivity checks.
Daily CHIRPS files are on a 0.05-degree longitude/latitude grid.

Two CHIRPS details matter for this folder:

- CHIRPS covers 50S to 50N only. A unit with any population or land area
  outside that band gets missing precipitation, even if most of it is inside
  (coverage_status = outside_chirps in the admin summary). For ex Nord in
  France has 0.1% of its population inside the band and Somme 66%, both are
  missing.
- A few small coastal or island polygons have CHIRPS weights, but the assigned
  precipitation cell is masked in the raw CHIRPS file. Those cases are listed in
  [shapefiles_chirps.csv](shapefiles_chirps.csv).

Precipitation powers are calculated at the CHIRPS grid-cell level before admin
averaging:

```text
daily grid-cell precip -> precip, precip^2, ..., precip^5 -> admin average
```

This keeps rainfall extremes and nonlinearities inside the admin unit before
values are averaged to the admin level.

## Raw Data

```text
/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP
```

## Output Location

Generated files are written outside the repo:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data
```

Country-year precipitation files:

```text
CHIRPS/<COUNTRY>/daily/
CHIRPS/<COUNTRY>/monthly/
CHIRPS/<COUNTRY>/annual/
```

Admin-to-CHIRPS weights:

```text
weights/landscan2011/CHIRPS/<COUNTRY>/
```

Keep large outputs outside the repo.

## Scripts

```text
shapefiles_chirps.csv
settings.py
common.py
aggregation_scripts/
jobs/
```

[shapefiles_chirps.csv](shapefiles_chirps.csv) has one row per country: the
shapefile, admin ID and name columns, ID widths, output subfolder and the
CHIRPS small-cell rules.

[settings.py](settings.py) reads that CSV and sets the years (1981-2025 for
every country) and the input and output paths.

[common.py](common.py) defines checks, CSV writing, admin ID handling,
shapefile reading, and CHIRPS grid reading. It drops the BARMM zones for PHL
and clips Tierra del Fuego for ARG.

[aggregation_scripts/01_make_weights.py](aggregation_scripts/01_make_weights.py)
builds fixed admin-to-CHIRPS-cell weights. Population weights use LandScan
2011. Area weights use GPW 2010 land-area points, not GPW population. These
weights are reused for all years.

GPW stands for Gridded Population of the World. Here we use its land-area data,
not its population data. In this repo, the GPW land-area data are stored as a
parquet point table. Each point is the center of a small GPW grid cell, and
`land_area` is the land area represented by that cell. The point location assigns
land area to an admin polygon and to a CHIRPS grid cell. The script then sums
land area by admin unit and CHIRPS cell and normalizes those totals into area
weights.

LandScan 2011 population raster:

```text
/project/cil/battuta_shares/gcp/social/sources/Landscan2011/RasterGISbinary/lspop2011.flt
```

GPW land-area point table:

```text
/project/cil/gcp/temp_data/gpw_2010_land_area_points
```

[aggregation_scripts/02_aggregate_daily.py](aggregation_scripts/02_aggregate_daily.py)
reads daily CHIRPS precipitation and writes daily, monthly, and annual admin
files.

[aggregation_scripts/03_check_outputs.py](aggregation_scripts/03_check_outputs.py)
checks source files, weights, row counts, columns, and annual non-missing
precipitation.

The matching sbatch files are in [jobs/](jobs/).

## Countries

```text
ARG AUS BRA_STABLE BWA CHL CHN COL CPV CRI ECU EU FRA IND JPN KOR MEX PER PHL RWA THA USA
```

Every ERA5-Land country except CAN (most census divisions are north of 50N).

Countries cut by the 50S/50N edge:

- ARG: Tierra del Fuego (province 94) and Santa Cruz
- CHL: 9 comunas in Magallanes are outside, 1 partly
- CHN: 9 counties in the far north are outside, 5 partly
- FRA: 1 department is outside, 5 partly
- USA: Alaska is outside
- EU: 169 NUTS2 regions fully inside, 27 partly (northern France, Belgium,
  Luxembourg, Germany, Czechia, Poland), 124 outside (UK, Ireland, Netherlands,
  Nordic and Baltic countries, most of Germany and Poland)

Countries with changed boundaries (COL, ECU, PER, PHL, THA) write to a
current_boundaries subfolder.

## Small-Cell Rules

CHIRPS has two separate small-cell issues.

Some small polygons contain no CHIRPS grid-cell center. For countries with
`uncovered_cell_rule="nearest_grid_cell"`,
[01_make_weights.py](aggregation_scripts/01_make_weights.py) uses the CHIRPS
cell containing a representative point inside the polygon.

Some coastal or island polygons have weights, but the assigned CHIRPS
precipitation cells are masked in the raw file. For countries with
`masked_cell_rule="nearest_valid_cell"`,
[02_aggregate_daily.py](aggregation_scripts/02_aggregate_daily.py) copies
values from a nearby finite CHIRPS cell within the country-specific radius.

## Usual Run Order

The commands below use Colombia as an example. Replace `COL` and the year range
with the country and years you need.

Submit jobs from the climate aggregation folder:

```bash
cd /path/to/rainfall-mortality-2026/1_data/climate_data/climate_aggregation_global
```

Build weights:

The weight job has two steps.

First, split the country's shapefile into chunks and build weights for each
chunk. These are chunks of admin polygons, not years. For this Colombia example,
`20` means the Colombia admin units are split into 20 chunks, and `%6` means at
most 6 chunks run at the same time.

```bash
sbatch --array=0-19%6 chirps_admin/jobs/01_weights.sbatch COL 20
```

After those 20 chunks finish, combine them into the final weight files (add
--overwrite after the chunk count to rebuild existing final weights):

```bash
sbatch chirps_admin/jobs/01_combine_weights.sbatch COL 20
```

The combine job writes the final weight file and admin summary, then runs the
country-level check.

Aggregate daily, monthly, and annual precipitation files:

```bash
sbatch --array=1981-2025%6 chirps_admin/jobs/02_daily.sbatch COL
```

This array is split by years. Each task writes one country-year of daily,
monthly, and annual precipitation, then runs the country-year check.

### Current-boundary run

Weight chunks per country (more chunks for countries with many units):

```bash
sbatch --array=0-1%6   chirps_admin/jobs/01_weights.sbatch ARG 2
sbatch --array=0-39%6  chirps_admin/jobs/01_weights.sbatch BRA_STABLE 40
sbatch --array=0-4%6   chirps_admin/jobs/01_weights.sbatch BWA 5
sbatch --array=0-4%6   chirps_admin/jobs/01_weights.sbatch CHL 5
sbatch --array=0-29%6  chirps_admin/jobs/01_weights.sbatch CHN 30
sbatch --array=0-9%6   chirps_admin/jobs/01_weights.sbatch COL 10
sbatch --array=0       chirps_admin/jobs/01_weights.sbatch CPV 1
sbatch --array=0-4%6   chirps_admin/jobs/01_weights.sbatch CRI 5
sbatch --array=0-2%6   chirps_admin/jobs/01_weights.sbatch ECU 3
sbatch --array=0-9%6   chirps_admin/jobs/01_weights.sbatch EU 10
sbatch --array=0-2%6   chirps_admin/jobs/01_weights.sbatch FRA 3
sbatch --array=0-2%6   chirps_admin/jobs/01_weights.sbatch PER 3
sbatch --array=0-9%6   chirps_admin/jobs/01_weights.sbatch PHL 10
sbatch --array=0       chirps_admin/jobs/01_weights.sbatch RWA 1
sbatch --array=0-2%6   chirps_admin/jobs/01_weights.sbatch THA 3
sbatch --array=0-29%6  chirps_admin/jobs/01_weights.sbatch USA 30
```

Then one combine job per country with the same chunk count, for ex
`sbatch chirps_admin/jobs/01_combine_weights.sbatch USA 30`, and one year array
per country, for ex
`sbatch --array=1981-2025%6 chirps_admin/jobs/02_daily.sbatch USA`.

AUS, IND, JPN, KOR and MEX keep their earlier weights, so they only need the
year array. Years already on disk are skipped.

Check one country-year:

```bash
/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python \
  chirps_admin/aggregation_scripts/03_check_outputs.py \
  --country COL --year 2000
```

Slurm logs go under:

```text
logs/chirps_admin/<COUNTRY>/
logs/chirps_admin/<COUNTRY>/weights/
```
