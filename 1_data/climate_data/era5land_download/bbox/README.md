# ERA5-Land Download Domains

These scripts document how the project ERA5-Land download boxes were made.

The domain files are not stored in GitHub. They live here:

```text
/project/cil/gcp/estimation/rainfall-mortality/era5land_domains
```

The daily climate rasters live separately:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily
```

## Scripts

`build_era5land_domains.R` builds the planned download domains from country shapes, HydroBASINS, and the few manual patches we needed. It writes all domain files to the battuta location.

`plot_raster_coverage.py` reads the daily NetCDF files and plots the boxes covered by the region folders. These are the maps used in the climate data note.

## Domain Decisions

The USA box was built from the USA country shape plus intersecting HydroBASINS Level 1. This made the box larger than the country border, but it was needed for the hydrology work.

The USA box covered most of Mexico, but not the southern edge. I added a narrow `mexico_south` strip and later merged `usa` and `mexico_south` into the final `mexico` folder. That folder should eventually be renamed `north_america`.

The India box was built from the India country shape plus intersecting HydroBASINS Level 1. I capped it at 120E so the first download did not pull a much larger East Asia/Pacific box before we knew it was needed.

Later, other Asian countries needed coverage, so I added `asia_east` and merged it with `india` into `asia_combined`. That folder can be renamed `asia`.

The LATAM box was meant to cover Latin America and the Caribbean. During Brazil aggregation, a small part of eastern Brazil was outside the raster. I added `brazil_east` and merged it with `latam` into the final `brazil` folder. That folder should eventually be renamed `latin_america`.

The Europe box was built from the mortality NUTS regions plus intersecting HydroBASINS Level 3. French overseas NUTS regions were removed.

The Australia box was built from the country shapefile. One far-southern outlying polygon was dropped so the box did not stretch too far south.

## Outputs

`build_era5land_domains.R` writes domain files, bbox files, and check plots to:

```text
/project/cil/gcp/estimation/rainfall-mortality/era5land_domains
```

`plot_raster_coverage.py` reads NetCDF headers from the daily climate files and writes the three raster coverage maps.

## Running

Use the project R environment:

```bash
env PROJ_LIB=/project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/share/proj \
  /project/cil/home_dirs/mdefranciosi/envs/mortality-rainfall-env/bin/Rscript \
  build_era5land_domains.R
```

Use the ERA5-Land Python environment for raster coverage maps:

```bash
/project/cil/home_dirs/mdefranciosi/envs/era5land/bin/python plot_raster_coverage.py
```

Both scripts are safe to rerun. They overwrite project-specific domain records and plots in:

```text
/project/cil/gcp/estimation/rainfall-mortality/era5land_domains
```
