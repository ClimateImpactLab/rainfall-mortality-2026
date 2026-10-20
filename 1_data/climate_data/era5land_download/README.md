# ERA5-Land Climate Data

This folder contains the scripts used to download and prepare ERA5-Land data for the rainfall-mortality project.

ERA5-Land is global, hourly, and stored on a 0.1-degree grid.
The full hourly archive is too large for this project to download as a single global dataset.
The mortality data only cover specific countries and years, so I downloaded regional (bounding) boxes instead.

The first boxes were built around India and the United States. 
Those boxes were larger than the country borders because they also had to cover the relevant HydroBASINS intersections. 
Later I added more regional downloads and a few patches where the original boxes did not fully cover the countries we needed.

The daily climate files are not stored in this repo. They are here:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily
```

Domain files, bounding-box files, and bbox check maps are stored here:

```text
/project/cil/gcp/estimation/rainfall-mortality/era5land_domains
```

## Download Steps:

The data were downloaded one region-month at a time.

I first used the Copernicus CDS API. It worked, but large requests were slow and often sat in the queue. 
I later used the DestinE Earth Data Hub for many downloads because it was much faster for this region-month setup.

Both routes do the same thing after the hourly data are opened:

1. aggregate hourly data to daily variables;
2. save daily NetCDF files in Battuta;
3. delete the hourly intermediate files.

Hourly files are not kept because they are too large.

Precipitation needs special handling. 
ERA5-Land total precipitation is accumulated, not an hourly rain rate.
The scripts shift timestamps back by one hour, take the daily maximum, and convert meters to millimeters.

## Why Not Download the Globe?

Global files would be cleaner, but this code starts from hourly data.
That is a lot to pull for places outside the mortality sample.
If we move to global data, we should test an existing daily product first.
That may be faster, but some variables would not be built the exact same way.

## Where Files Are Saved

The download scripts first save daily files in Battuta:

```text
/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily/<region>/<year>/
```

At this stage, each file is one region-month and contains all daily variables:

```text
era5land_daily_<region>_<year>_<month>.nc
```

The transform scripts then copy the same data into the folder structure used by the rest of the project:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily/<region>/<variable>/
```

There, each file is one region, one variable, and one year of daily values:

```text
era5land_<region>_<variable>_<year>.nc4
```

## Daily Variables

The final daily files are organized like this:

```text
/project/cil/gcp/climate/ERA5-LAND/raw/daily/<region>/<variable>/era5land_<region>_<variable>_<year>.nc4
```

The variables are:

| Variable | Meaning | Units |
|---|---|---|
| `tmin` | daily minimum 2m air temperature | degC |
| `tmean` | daily mean 2m air temperature | degC |
| `tmax` | daily maximum 2m air temperature | degC |
| `rh_mean` | daily mean relative humidity | percent |
| `q_mean` | daily mean specific humidity | g/kg |
| `swe_mean` | daily mean snow water equivalent | mm |
| `tp_total` | daily total precipitation | mm |
| `wind_max` | daily maximum 10m wind speed | m/s |

## Region Names

The region names are confusing. Some folders are named after the country I was trying to fix at the time, not the full area covered by the raster. I should have cleaned this up before the hydrology processing started.

Use these final folders:

| Current folder | Better name | What happened |
|---|---|---|
| `asia_combined` | `asia` | `india` was merged with `asia_east` to cover other Asian countries in the sample. |
| `mexico` | `north_america` | `usa` covered most of Mexico, but not the southern edge, so `mexico_south` was added. |
| `brazil` | `latin_america` | `latam` missed a small part of eastern Brazil, so `brazil_east` was added. |
| `europe` | `europe` | Direct regional download. |
| `australia` | `australia` | Direct regional download. |

Do not use these component folders as final analysis domains:

```text
india
asia_east
usa
mexico_south
latam
brazil_east
```

They are useful for checking how the merged files were made, but they should not be the domains used for analysis.

## Scripts

`download/` downloads hourly ERA5-Land data and saves daily files. It contains both the CDS and DestinE routes.

`transform/` converts monthly daily files into annual single-variable files and merges component regions into the final folders.

`bbox/` records how the planned download boxes were made and plots the boxes from the actual rasters.

## More Detail

The climate data note is here:

```text
ERA5_Land_Climate_Data_Note.pdf
```
