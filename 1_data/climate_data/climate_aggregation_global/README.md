# Climate Aggregation Global

This folder aggregates gridded climate data to the admin units used in the
rainfall-mortality project.

The main ERA5-Land code is in [era5land_admin/](era5land_admin/). It reads the
global ERA5-Land files and writes `ERA5-LAND-GLOBAL` outputs.

The heavy raster and NetCDF steps are run through the sbatch files in the code
folder job folders:
[era5land_admin/jobs/](era5land_admin/jobs/),
[chirps_admin/jobs/](chirps_admin/jobs/), and
[era5land_us_state_month/jobs/](era5land_us_state_month/jobs/).

## Folders

[era5land_admin/](era5land_admin/) is the ERA5-Land aggregation code for the
mortality panel admin units. It rebuilds weights on the global ERA5-Land grid
and aggregates daily precipitation, temperature, and wind.

[chirps_admin/](chirps_admin/) is the CHIRPS precipitation aggregation code for the same
mortality panel admin units. It is used for precipitation sensitivity checks.
CHIRPS does not cover the full globe, so only countries within the CHIRPS
latitude range are included.

[era5land_us_state_month/](era5land_us_state_month/) is the U.S. state-month
ERA5-Land code used for the tropical-cyclone confounding check. It follows the
Young-Hsiang state-month setup and builds all-weather wind and precipitation
files for U.S. states.

[hydro_era5land_admin/](hydro_era5land_admin/) is reserved for future
hydrology aggregation scripts.

Each active folder has its own README with run order, inputs, outputs, and
caveats:

- [era5land_admin/README.md](era5land_admin/README.md)
- [chirps_admin/README.md](chirps_admin/README.md)
- [era5land_us_state_month/README.md](era5land_us_state_month/README.md)
- [hydro_era5land_admin/README.md](hydro_era5land_admin/README.md)

## How the Aggregation Works

The goal is to turn daily climate grid cells into climate values for each admin
unit.

The main inputs are:

- an admin shapefile, which gives the admin polygons
- a climate raster or NetCDF file, which gives daily climate values by grid cell
- LandScan 2011 population, used for population weights
- GPW 2010 land-area points, used for area weights

The first step is to build weights. A weight says how much a climate grid cell
counts for one admin unit.

The weight file is at the level:

```text
admin unit x climate grid cell
```

Each admin unit gets two sets of weights:

- `popwt`: based on where people live inside the admin unit
- `areawt`: based on where land area falls inside the admin unit

For population weights, the code uses LandScan:

```text
LandScan pixel center -> admin polygon -> climate grid cell
```

It keeps LandScan pixels whose centers fall inside the admin polygon. Then it
assigns those pixels to climate grid cells, sums population by admin unit and
climate cell, and divides by total LandScan population in that admin unit.

For area weights, the code uses GPW land-area points:

```text
GPW point -> admin polygon -> climate grid cell
```

GPW stands for Gridded Population of the World. Here we use the GPW land-area
data, not GPW population. In this repo, GPW land area is stored as a point
table. Each point is the center of a small GPW grid cell, and the `land_area`
column gives the land area represented by that cell. The point itself has no
area; it is just the location used to assign the cell's land area.

For both population and area weights, boundary cells are assigned by their
center point. A small LandScan pixel or GPW land-area point goes to the admin
polygon that contains its center. Climate grid cells can still enter more than
one admin unit, because different admin units can place different weights on
the same climate cell.

After weights are built, daily aggregation is simple:

```text
admin climate = sum(climate cell value x weight)
```

This is done once with `popwt` and once with `areawt`.

For precipitation powers, the power is taken before aggregation:

```text
daily grid-cell precip -> precip, precip^2, ..., precip^5 -> admin average
```

That is not the same as averaging precipitation first and then taking powers.
The code keeps the grid-cell nonlinear terms first, then averages them to admin
units. This preserves more of the within-admin rainfall extremes and
nonlinearities before the values enter the regressions.

Some small coastal or island units need extra care. They can have population or
area weights, but the raw climate file can still have missing values for the
assigned cells. For ERA5-Land, this usually comes from the ERA5-Land land mask.
The reviewed nearby-cell cases are described in
[era5land_admin/cell_fallback/README.md](era5land_admin/cell_fallback/README.md).
CHIRPS has similar coastal/island cases handled inside the CHIRPS settings and
aggregation code.

## Output Location

Generated files are written outside the repo:

```text
/project/cil/gcp/estimation/rainfall-mortality/climate_data
```

Main ERA5-Land outputs are under:

```text
ERA5-LAND-GLOBAL/<COUNTRY>/
ERA5-LAND-GLOBAL/combined/
weights/landscan2011/ERA5-LAND-GLOBAL/<COUNTRY>/
```

CHIRPS outputs are under:

```text
CHIRPS/<COUNTRY>/
weights/landscan2011/CHIRPS/<COUNTRY>/
```

U.S. state-month climate files are under:

```text
ERA5-LAND/USA/state_month/
```
