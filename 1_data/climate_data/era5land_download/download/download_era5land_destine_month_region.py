#!/usr/bin/env python3
"""
download_era5land_destine_month_region.py

Download one ERA5-Land region-month from DestinE and aggregate it to daily data.

Why this exists
---------------
ERA5-Land is hourly. Pulling the full global hourly archive is too large for
this project, so the download is split into one region-month per Slurm task.
DestinE was faster than the CDS API for these regional downloads.

Inputs
------
* DestinE ERA5-Land Zarr store.
* A region name and year-month.
* The project bounding-box GPKG.
* EDH_TOKEN in the environment. Run `source ~/.env_destine` before submitting.

Outputs
-------
One compressed monthly daily NetCDF:

    <data-root>/processed/daily/<region>/<year>/
        era5land_daily_<region>_<year>_<month>.nc

The hourly data are not saved. Temporary daily blocks are written to scratch
and removed at the end unless `--keep-temp` is used.

Rerun notes
-----------
Safe to rerun if the output is absent. Use `--overwrite` only when replacing an
existing file on purpose. This script reads a large remote Zarr dataset and
should run on a compute node, not the login node.

Important assumption
--------------------
ERA5-Land total precipitation is accumulated. It is shifted back by one hour
and the daily maximum is used. Do not sum raw hourly precipitation values.
"""

# =============================================================================
# 1. Imports
# =============================================================================

import argparse
import calendar
import os
import shutil
import time
from pathlib import Path
from urllib.parse import quote

try:
    import geopandas as gpd
    import numpy as np
    import xarray as xr
except ImportError as e:
    raise SystemExit(
        "Missing package. Need: geopandas, numpy, xarray, zarr, fsspec, "
        "netCDF4, pandas, dask.\n"
        f"Original error: {e}"
    )


# =============================================================================
# 2. Paths and Constants
# =============================================================================

DESTINE_ZARR_URL = (
    "https://data.earthdatahub.destine.eu/era5/"
    "reanalysis-era5-land-no-antartica-v0.zarr"
)

DEFAULT_BBOX_FILE = (
    "/project/cil/gcp/estimation/rainfall-mortality/"
    "era5land_domains/data/bbox/regional_era5land_bounding_boxes.gpkg"
)

RAW_VARIABLES = ["t2m", "d2m", "tp", "sd", "sp", "u10", "v10"]

# DestinE grid coordinates sometimes differ from exact 0.1 degree values by a
# tiny amount. This buffer keeps cells on the bbox edge from being dropped.
COORDINATE_TOLERANCE_DEGREES = 1e-6


# =============================================================================
# 3. Arguments
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser()

    # Each Slurm task downloads one region-month.
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--month", type=int, required=True)
    parser.add_argument(
        "--region",
        type=str,
        required=True,
        choices=[
            "europe",
            "usa",
            "india",
            "latam",
            "australia",
            "asia_east",
            "mexico_south",
            "brazil_east",
        ],
    )
    parser.add_argument("--bbox-file", type=str, default=DEFAULT_BBOX_FILE)
    parser.add_argument(
        "--data-root",
        type=str,
        default="/project/cil/battuta_shares/gcp/climate/ERA5-LAND",
    )
    parser.add_argument(
        "--scratch-root",
        type=str,
        default=os.environ.get("SLURM_TMPDIR", "/tmp"),
    )
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--overwrite", action="store_true")

    return parser.parse_args()


# =============================================================================
# 4. Bounding Box and DestinE Helpers
# =============================================================================

def load_region_area(region: str, bbox_file: str) -> list[float]:
    # Read the project bbox file and return the box as
    # [north, west, south, east].
    bbox_file = Path(bbox_file)

    if not bbox_file.exists():
        raise FileNotFoundError(f"Bbox file not found: {bbox_file}")

    gdf = gpd.read_file(bbox_file)

    if gdf.empty:
        raise ValueError(f"Bbox file is empty: {bbox_file}")

    if "domain" in gdf.columns:
        domain = gdf["domain"].astype(str)

        # The bbox file uses longer labels than the command-line region names.
        # This block links the short name to the right row.
        if region == "europe":
            candidates = gdf[domain.str.contains("Europe", case=False, na=False)]
        elif region == "usa":
            candidates = gdf[domain.str.contains("USA", case=False, na=False)]
        elif region == "india":
            candidates = gdf[domain.str.contains("India", case=False, na=False)]
        elif region == "latam":
            candidates = gdf[domain.str.contains("Latin", case=False, na=False)]
        elif region == "australia":
            candidates = gdf[domain.str.contains("Australia", case=False, na=False)]
        elif region == "asia_east":
            candidates = gdf[
                domain.str.contains("Asia east extension", case=False, na=False)
            ]
        elif region == "mexico_south":
            candidates = gdf[
                domain.str.contains("Mexico south extension", case=False, na=False)
            ]
        elif region == "brazil_east":
            candidates = gdf[
                domain.str.contains("Brazil east coastal extension", case=False, na=False)
            ]
        else:
            candidates = gdf.iloc[0:0]

        if candidates.empty:
            raise ValueError(
                f"No bounding box found for region={region}. "
                f"Available domains: {sorted(domain.dropna().unique())}"
            )
        gdf = candidates

    west, south, east, north = gdf.geometry.iloc[0].bounds
    return [float(north), float(west), float(south), float(east)]


def authenticated_destine_url() -> str:
    # DestinE needs the token in the URL. Quote it so special characters do not
    # break the path.
    token = os.environ.get("EDH_TOKEN")

    if not token:
        raise RuntimeError(
            "EDH_TOKEN is not set. Run `source ~/.env_destine` before this script."
        )

    token_safe = quote(token, safe="")
    return DESTINE_ZARR_URL.replace("https://", f"https://edh:{token_safe}@")


def open_destine_dataset() -> xr.Dataset:
    # Open lazily. This reads metadata now; the data are pulled later.
    return xr.open_dataset(
        authenticated_destine_url(),
        engine="zarr",
        chunks={},
    )


def lon_to_0360(lon: float) -> float:
    # DestinE uses 0..360 longitude, while our bboxes use -180..180.
    return lon % 360


def subset_lon_0360(ds: xr.Dataset, west: float, east: float) -> xr.Dataset:
    """
    Subset native 0..360 longitudes using bbox west/east in -180..180,
    then return clean -180..180 longitudes.

    This avoids sorting the full global Zarr dataset, but saves clean regional
    output coordinates.
    """

    west_360 = lon_to_0360(west)
    east_360 = lon_to_0360(east)

    print(
        f"Longitude bbox input west/east: {west}, {east}; "
        f"converted to 0..360: {west_360}, {east_360}",
        flush=True,
    )

    if west < 0 < east:
        # If the box crosses Greenwich, it becomes two slices in 0..360 space.
        print("Longitude bbox crosses Greenwich. Using two slices.", flush=True)

        ds_west = ds.sel(longitude=slice(west_360, 360))
        ds_east = ds.sel(longitude=slice(0, east_360))
        out = xr.concat([ds_west, ds_east], dim="longitude")
    else:
        out = ds.sel(longitude=slice(west_360, east_360))

    # Save regional files back in -180..180 longitude so they match shapefiles.
    out = out.assign_coords(
        longitude=((out.longitude + 180) % 360) - 180
    ).sortby("longitude")

    return out


# =============================================================================
# 5. Meteorological Helpers
# =============================================================================

def saturation_vapor_pressure_hpa(temp_c):
    return 6.112 * np.exp((17.67 * temp_c) / (temp_c + 243.5))


def compute_relative_humidity(t2m_c, d2m_c):
    # Compute RH hourly first, then average the hourly values to daily.
    es_t = saturation_vapor_pressure_hpa(t2m_c)
    es_td = saturation_vapor_pressure_hpa(d2m_c)
    return (100.0 * (es_td / es_t)).clip(min=0.0, max=100.0)


def compute_specific_humidity_gkg(d2m_c, sp_pa):
    # The formula uses hPa, so convert surface pressure from Pa first.
    e_hpa = saturation_vapor_pressure_hpa(d2m_c)
    p_hpa = sp_pa / 100.0
    q_kgkg = (0.622 * e_hpa) / (p_hpa - 0.378 * e_hpa)
    return q_kgkg * 1000.0


def add_metadata(ds: xr.Dataset, region: str, area: list[float]) -> xr.Dataset:
    # Add units and notes so the saved NetCDF can be understood on its own.
    meta = {
        "tmin": {"long_name": "Daily minimum 2m air temperature", "units": "degC"},
        "tmean": {"long_name": "Daily mean 2m air temperature", "units": "degC"},
        "tmax": {"long_name": "Daily maximum 2m air temperature", "units": "degC"},
        "rh_mean": {
            "long_name": "Daily mean relative humidity",
            "units": "%",
            "note": "Computed hourly from 2m temperature and dew point, then averaged daily.",
        },
        "q_mean": {
            "long_name": "Daily mean specific humidity",
            "units": "g/kg",
            "note": "Computed hourly from dew point and surface pressure, then averaged daily.",
        },
        "swe_mean": {
            "long_name": "Daily mean snow water equivalent",
            "units": "mm",
            "note": "Daily mean of hourly snow depth water equivalent, converted m to mm.",
        },
        "tp_total": {
            "long_name": "Daily total precipitation",
            "units": "mm",
            "note": (
                "Computed from ERA5-Land accumulated hourly precipitation. "
                "Timestamps shifted back 1 hour, daily maximum accumulation used, "
                "converted m to mm."
            ),
        },
        "wind_max": {
            "long_name": "Daily maximum 10m wind speed",
            "units": "m/s",
            "note": "Computed hourly as sqrt(u10^2 + v10^2), then daily maximum.",
        },
    }

    for var, attrs in meta.items():
        if var in ds:
            ds[var].attrs.update(attrs)

    ds.attrs.update(
        {
            "title": f"ERA5-Land daily aggregated climate data for {region}",
            "source": "ERA5-Land hourly data from DestinE Earth Data Hub Zarr",
            "region": region,
            "area_north_west_south_east": str(area),
            "aggregation_note": (
                "Temperature aggregated to daily min/mean/max. Humidity metrics "
                "computed hourly and averaged daily. Snow averaged daily. "
                "Precipitation computed from accumulated field using timestamp "
                "shift and daily maximum. Wind speed computed from u10/v10 and "
                "aggregated to daily maximum."
            ),
        }
    )

    return ds


def compression_encoding(ds: xr.Dataset) -> dict:
    # Compress the final NetCDF without changing the daily values.
    return {
        var: {"zlib": True, "complevel": 4, "dtype": "float32"}
        for var in ds.data_vars
    }


# =============================================================================
# 6. Main Processing
# =============================================================================

def main():
    args = parse_args()

    year = args.year
    month = args.month
    region = args.region.lower()

    area = load_region_area(region, args.bbox_file)
    north, west, south, east = area

    data_root = Path(args.data_root)
    scratch_root = Path(args.scratch_root)

    days_in_month = calendar.monthrange(year, month)[1]

    # Need next month 00:00 because that timestamp contains the final rain
    # accumulation for the last day of this month.
    if month == 12:
        next_year = year + 1
        next_month = 1
    else:
        next_year = year
        next_month = month + 1

    month_start = np.datetime64(f"{year}-{month:02d}-01")
    month_end = np.datetime64(f"{year}-{month:02d}-{days_in_month:02d}")

    time_start = f"{year}-{month:02d}-01T00:00:00"
    time_end_with_buffer = f"{next_year}-{next_month:02d}-01T00:00:00"

    # This script saves the first-pass monthly files. The transform scripts
    # later reshape them into annual files by variable.
    final_dir = data_root / "processed" / "daily" / region / f"{year}"
    final_dir.mkdir(parents=True, exist_ok=True)

    final_daily_file = final_dir / f"era5land_daily_{region}_{year}_{month:02d}.nc"

    if final_daily_file.exists() and not args.overwrite:
        print(f"Final output already exists, skipping: {final_daily_file}", flush=True)
        return

    if final_daily_file.exists() and args.overwrite:
        print(f"Overwriting existing final output: {final_daily_file}", flush=True)
        final_daily_file.unlink()

    # Write temporary files to scratch. Only the finished file is moved to the
    # shared climate folder.
    month_scratch = scratch_root / f"era5land_destine_{region}_{year}_{month:02d}"
    interm_dir = month_scratch / "intermediate"
    interm_dir.mkdir(parents=True, exist_ok=True)

    temp_daily_file = interm_dir / f"temp_daily_{region}_{year}_{month:02d}.nc"
    humidity_daily_file = interm_dir / f"humidity_daily_{region}_{year}_{month:02d}.nc"
    snow_daily_file = interm_dir / f"snow_daily_{region}_{year}_{month:02d}.nc"
    precip_daily_file = interm_dir / f"precip_daily_{region}_{year}_{month:02d}.nc"
    wind_daily_file = interm_dir / f"wind_daily_{region}_{year}_{month:02d}.nc"

    final_tmp_file = month_scratch / f"era5land_daily_{region}_{year}_{month:02d}.nc"

    t0 = time.time()

    print("===== ERA5-LAND DESTINE DIRECT DAILY PROCESSING =====", flush=True)
    print(f"Region: {region}", flush=True)
    print(f"Year-month: {year}-{month:02d}", flush=True)
    print(f"Bbox file: {args.bbox_file}", flush=True)
    print(f"Area [north, west, south, east]: {area}", flush=True)
    print(f"Time start: {time_start}", flush=True)
    print(f"Time end with buffer: {time_end_with_buffer}", flush=True)
    print(f"Scratch workspace: {month_scratch}", flush=True)
    print(f"Final output: {final_daily_file}", flush=True)
    print("===================================================", flush=True)

    print("Opening DestinE Zarr dataset...", flush=True)
    t_zarr_open_start = time.time()

    ds_zarr = open_destine_dataset()

    t_zarr_open_end = time.time()
    print(
        f"DestinE open time: {(t_zarr_open_end - t_zarr_open_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Creating regional/monthly DestinE subset...", flush=True)
    t_subset_start = time.time()

    # ERA5-Land latitude is ordered north to south, so the slice uses that order.
    ds = ds_zarr[RAW_VARIABLES].sel(
        valid_time=slice(time_start, time_end_with_buffer),
        latitude=slice(
            north + COORDINATE_TOLERANCE_DEGREES,
            south - COORDINATE_TOLERANCE_DEGREES,
        ),
    )

    ds = subset_lon_0360(ds, west=west, east=east)
    # Use one-day chunks because all outputs below are daily summaries.
    ds = ds.chunk({"valid_time": 24})

    print(ds, flush=True)

    t_subset_end = time.time()
    print(
        f"Subset setup time: {(t_subset_end - t_subset_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Aggregating temperature block...", flush=True)
    t_temp_start = time.time()

    # ERA5-Land temperature is Kelvin. Save daily temperature in Celsius.
    t2m_c = ds["t2m"] - 273.15

    temp_daily = xr.Dataset(
        {
            "tmin": t2m_c.resample(valid_time="1D").min(),
            "tmean": t2m_c.resample(valid_time="1D").mean(),
            "tmax": t2m_c.resample(valid_time="1D").max(),
        }
    ).sel(valid_time=slice(month_start, month_end))

    temp_daily.to_netcdf(temp_daily_file)
    del temp_daily

    t_temp_end = time.time()
    print(
        f"Temperature block time: {(t_temp_end - t_temp_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Computing and aggregating humidity block...", flush=True)
    t_humidity_start = time.time()

    # Relative humidity and specific humidity are built from hourly temperature,
    # dew point, and pressure before daily averaging.
    d2m_c = ds["d2m"] - 273.15
    sp_pa = ds["sp"]

    rh = compute_relative_humidity(t2m_c, d2m_c)
    q_gkg = compute_specific_humidity_gkg(d2m_c, sp_pa)

    humidity_daily = xr.Dataset(
        {
            "rh_mean": rh.resample(valid_time="1D").mean(),
            "q_mean": q_gkg.resample(valid_time="1D").mean(),
        }
    ).sel(valid_time=slice(month_start, month_end))

    humidity_daily.to_netcdf(humidity_daily_file)

    del d2m_c, sp_pa, rh, q_gkg, humidity_daily, t2m_c

    t_humidity_end = time.time()
    print(
        f"Humidity block time: {(t_humidity_end - t_humidity_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Aggregating snow water equivalent block...", flush=True)
    t_snow_start = time.time()

    # Snow water equivalent is in meters. Save it in millimeters.
    snow_daily = xr.Dataset(
        {
            "swe_mean": (ds["sd"].resample(valid_time="1D").mean() * 1000.0),
        }
    ).sel(valid_time=slice(month_start, month_end))

    snow_daily.to_netcdf(snow_daily_file)
    del snow_daily

    t_snow_end = time.time()
    print(
        f"Snow block time: {(t_snow_end - t_snow_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Aggregating precipitation block using ERA5-Land accumulation logic...", flush=True)
    t_precip_start = time.time()

    # ERA5-Land rain is accumulated. The midnight value belongs to the day that
    # just ended, so shift time back one hour before daily aggregation.
    tp_shifted = ds["tp"].assign_coords(
        valid_time=ds["valid_time"] - np.timedelta64(1, "h")
    )

    precip_daily = (
        tp_shifted.resample(valid_time="1D").max() * 1000.0
    ).to_dataset(name="tp_total")

    # Drop the extra buffer day after it has served its purpose.
    precip_daily = precip_daily.sel(valid_time=slice(month_start, month_end))
    precip_daily.to_netcdf(precip_daily_file)

    del tp_shifted, precip_daily

    t_precip_end = time.time()
    print(
        f"Precipitation block time: {(t_precip_end - t_precip_start) / 60:.2f} minutes",
        flush=True,
    )

    print("Computing and aggregating wind speed block...", flush=True)
    t_wind_start = time.time()

    # Wind speed is not downloaded directly. Compute it from the u and v wind
    # components, then take the daily maximum.
    wind_speed = np.sqrt(ds["u10"] ** 2 + ds["v10"] ** 2)

    wind_daily = xr.Dataset(
        {
            "wind_max": wind_speed.resample(valid_time="1D").max(),
        }
    ).sel(valid_time=slice(month_start, month_end))

    wind_daily.to_netcdf(wind_daily_file)

    del wind_speed, wind_daily

    t_wind_end = time.time()
    print(
        f"Wind block time: {(t_wind_end - t_wind_start) / 60:.2f} minutes",
        flush=True,
    )

    ds.close()
    ds_zarr.close()

    print("Merging daily outputs...", flush=True)
    t_merge_start = time.time()

    # Reopen the five temporary daily files and join them into one final file.
    temp_daily = xr.open_dataset(temp_daily_file)
    humidity_daily = xr.open_dataset(humidity_daily_file)
    snow_daily = xr.open_dataset(snow_daily_file)
    precip_daily = xr.open_dataset(precip_daily_file)
    wind_daily = xr.open_dataset(wind_daily_file)

    final_daily = xr.merge(
        [temp_daily, humidity_daily, snow_daily, precip_daily, wind_daily],
        compat="no_conflicts",
    )

    final_daily = add_metadata(final_daily, region=region, area=area)

    # Compress the final file. The block files are temporary.
    encoding = compression_encoding(final_daily)
    final_daily.to_netcdf(final_tmp_file, encoding=encoding)

    temp_daily.close()
    humidity_daily.close()
    snow_daily.close()
    precip_daily.close()
    wind_daily.close()
    final_daily.close()

    shutil.move(str(final_tmp_file), str(final_daily_file))

    t_merge_end = time.time()
    print(
        f"Merge/save final time: {(t_merge_end - t_merge_start) / 60:.2f} minutes",
        flush=True,
    )

    final_daily_size_gb = (
        final_daily_file.stat().st_size / 1024**3 if final_daily_file.exists() else 0
    )

    if not args.keep_temp:
        print("Cleaning up scratch workspace...", flush=True)
        shutil.rmtree(month_scratch, ignore_errors=True)

    t1 = time.time()

    print("\n===== SUMMARY =====", flush=True)
    print(f"Region:                   {region}", flush=True)
    print(f"Year-month:               {year}-{month:02d}", flush=True)
    print(f"Area:                     {area}", flush=True)
    print(f"Final daily file size:     {final_daily_size_gb:.2f} GB", flush=True)
    print(f"DestinE open time:         {(t_zarr_open_end - t_zarr_open_start) / 60:.2f} min", flush=True)
    print(f"Subset setup time:         {(t_subset_end - t_subset_start) / 60:.2f} min", flush=True)
    print(f"Temperature block time:    {(t_temp_end - t_temp_start) / 60:.2f} min", flush=True)
    print(f"Humidity block time:       {(t_humidity_end - t_humidity_start) / 60:.2f} min", flush=True)
    print(f"Snow block time:           {(t_snow_end - t_snow_start) / 60:.2f} min", flush=True)
    print(f"Precipitation block time:  {(t_precip_end - t_precip_start) / 60:.2f} min", flush=True)
    print(f"Wind block time:           {(t_wind_end - t_wind_start) / 60:.2f} min", flush=True)
    print(f"Merge/save final time:     {(t_merge_end - t_merge_start) / 60:.2f} min", flush=True)
    print(f"Total runtime:             {(t1 - t0) / 60:.2f} min", flush=True)


if __name__ == "__main__":
    main()
