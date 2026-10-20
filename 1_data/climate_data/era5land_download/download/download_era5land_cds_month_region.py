#!/usr/bin/env python3
"""
download_era5land_cds_month_region.py

Purpose
-------
Download hourly ERA5-Land data for one region-month, aggregate to daily
resolution, and save a compressed NetCDF file.

Why this exists
---------------
ERA5-Land is hourly. Pulling the full global hourly archive is too large for
this project, so the download is split into one region-month per Slurm task.
This CDS script was the first route used for India, the USA, and early patch
regions before most later downloads moved to DestinE.

Inputs
------
* Copernicus CDS API credentials, usually through CDSAPI_RC.
* A region name and year-month.
* The project bounding-box GPKG.

Output
------
One compressed monthly daily NetCDF:

    <data-root>/processed/daily/<region>/<year>/
        era5land_daily_<region>_<year>_<month>.nc

The hourly CDS files are written to scratch only and removed after a successful
run unless `--keep-temp` is used.

Rerun notes
-----------
Safe to rerun if the output is absent. Existing outputs are skipped. This
script downloads and aggregates large NetCDF files, so run it on a compute node
rather than the login node.

Final output variables
----------------------
1. tmin      : daily minimum 2m temperature, degC
2. tmean     : daily mean 2m temperature, degC
3. tmax      : daily maximum 2m temperature, degC
4. rh_mean   : daily mean relative humidity, %
5. q_mean    : daily mean specific humidity, g/kg
6. swe_mean  : daily mean snow water equivalent, mm
7. tp_total  : daily total precipitation, mm
8. wind_max  : daily maximum 10m wind speed, m/s

Important ERA5-Land precipitation note
--------------------------------------
ERA5-Land total precipitation is accumulated from the beginning of the forecast
cycle. It's not an hourly increment. Therefore, daily precipitation is computed
by:
    1. shifting timestamps back by 1 hour
    2. taking the daily maximum accumulated value
    3. converting m -> mm

Important windspeed note
------------------------
ERA5-Land does not provide wind speed directly here. We request the 10m u and v
wind components and compute hourly wind speed as:

    wind_speed = sqrt(u10^2 + v10^2)

Then daily wind speed is aggregated as the daily maximum.
"""

# =============================================================================
# 0. Imports
# =============================================================================

import argparse
import calendar
import os
import shutil
import time
from pathlib import Path

try:
    import cdsapi
    import geopandas as gpd
    import numpy as np
    import xarray as xr
except ImportError as e:
    raise SystemExit(
        "Missing required package. Need: cdsapi, geopandas, numpy, xarray, "
        "netCDF4, pandas, dask.\n"
        f"Original error: {e}"
    )


# =============================================================================
# 1. Constants
# =============================================================================

DEFAULT_BBOX_FILE = (
    "/project/cil/gcp/estimation/rainfall-mortality/"
    "era5land_domains/data/bbox/"
    "regional_era5land_bounding_boxes.gpkg"
)

CDS_DATASET = "reanalysis-era5-land"

RAW_VARIABLES = [
    "2m_temperature",
    "2m_dewpoint_temperature",
    "total_precipitation",
    "snow_depth_water_equivalent",
    "surface_pressure",
    "10m_u_component_of_wind",
    "10m_v_component_of_wind",
]


# =============================================================================
# 2. Argument parsing
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser()

    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--month", type=int, required=True)

    parser.add_argument(
        "--region",
        type=str,
        required=True,
        choices=["usa", "india", "asia_east"],
        help=(
            "Region name defined in the bounding box GPKG"
        ),
    )

    parser.add_argument(
        "--bbox-file",
        type=str,
        default=DEFAULT_BBOX_FILE,
        help="GPKG file containing region bounding boxes.",
    )

    parser.add_argument(
        "--data-root",
        type=str,
        default="/project/cil/battuta_shares/gcp/climate/ERA5-LAND",
        help="Permanent output root.",
    )

    parser.add_argument(
        "--scratch-root",
        type=str,
        default=os.environ.get("SLURM_TMPDIR", "/tmp"),
        help="Node-local scratch root.",
    )

    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep temporary scratch files after successful run.",
    )

    parser.add_argument(
        "--max-retries",
        type=int,
        default=5,
        help="Maximum number of CDS retries per request.",
    )

    parser.add_argument(
        "--retry-wait-seconds",
        type=int,
        default=180,
        help="Base wait time between retries.",
    )

    return parser.parse_args()


# =============================================================================
# 3. Bounding box utilities
# =============================================================================

def load_region_area(region: str, bbox_file: str) -> list[float]:
    """
    Load region bounding box from GPKG and return CDS area format.

    CDS expects:
        [north, west, south, east]
    """
    bbox_file = Path(bbox_file)

    if not bbox_file.exists():
        raise FileNotFoundError(f"Bbox file not found: {bbox_file}")

    gdf = gpd.read_file(bbox_file)

    if "domain" not in gdf.columns:
        raise ValueError(
            f"Expected column 'domain' in bbox file. Found: {list(gdf.columns)}"
        )

    if region == "usa":
        domain_name = "USA Level 1 bbox"
    elif region == "india":
        domain_name = "India Level 1 bbox capped at 120E"
    elif region == "asia_east":
        domain_name = "Asia east extension bbox 120.1E to 150E"
    else:
        raise ValueError(
            f"Unsupported region: {region}. "
            "If this is a new bbox region, add its domain name here."
        )

    match = gdf[gdf["domain"] == domain_name]

    if match.empty:
        raise ValueError(
            f"No bbox found for region={region} with domain='{domain_name}'. "
            f"Available domains: {sorted(gdf['domain'].dropna().unique())}"
        )

    west, south, east, north = match.geometry.iloc[0].bounds

    return [float(north), float(west), float(south), float(east)]


# =============================================================================
# 4. Meteorological formulas
# =============================================================================

def saturation_vapor_pressure_hpa(temp_c):
    """
    Saturation vapor pressure in hPa using Magnus formula.

    Input:
        temp_c : temperature in degrees Celsius

    Output:
        saturation vapor pressure in hPa
    """
    return 6.112 * np.exp((17.67 * temp_c) / (temp_c + 243.5))


def compute_relative_humidity(t2m_c, d2m_c):
    """
    Compute relative humidity from temperature and dew point.

    RH = 100 * es(Td) / es(T)
    """
    es_t = saturation_vapor_pressure_hpa(t2m_c)
    es_td = saturation_vapor_pressure_hpa(d2m_c)

    rh = 100.0 * (es_td / es_t)
    return rh.clip(min=0.0, max=100.0)


def compute_specific_humidity_gkg(d2m_c, sp_pa):
    """
    Compute specific humidity from dew point and surface pressure.

    e = es(Td)
    q = 0.622 * e / (p - 0.378 * e)

    Units:
        e: hPa
        p: hPa
        q output: g/kg
    """
    e_hpa = saturation_vapor_pressure_hpa(d2m_c)
    p_hpa = sp_pa / 100.0

    q_kgkg = (0.622 * e_hpa) / (p_hpa - 0.378 * e_hpa)
    return q_kgkg * 1000.0


# =============================================================================
# 5. Metadata and encoding
# =============================================================================

def add_metadata(ds: xr.Dataset, region: str, area: list[float]) -> xr.Dataset:
    """Attach variable-level and dataset-level metadata."""

    meta = {
        "tmin": {
            "long_name": "Daily minimum 2m air temperature",
            "units": "degC",
        },
        "tmean": {
            "long_name": "Daily mean 2m air temperature",
            "units": "degC",
        },
        "tmax": {
            "long_name": "Daily maximum 2m air temperature",
            "units": "degC",
        },
        "rh_mean": {
            "long_name": "Daily mean relative humidity",
            "units": "%",
            "note": (
                "Computed hourly from 2m temperature and 2m dew point "
                "temperature, then averaged daily."
            ),
        },
        "q_mean": {
            "long_name": "Daily mean specific humidity",
            "units": "g/kg",
            "note": (
                "Computed hourly from 2m dew point temperature and surface "
                "pressure, then averaged daily."
            ),
        },
        "swe_mean": {
            "long_name": "Daily mean snow water equivalent",
            "units": "mm",
            "note": (
                "Computed as daily mean of hourly snow depth water equivalent; "
                "converted from m water equivalent to mm."
            ),
        },
        "tp_total": {
            "long_name": "Daily total precipitation",
            "units": "mm",
            "note": (
                "Computed from ERA5-Land accumulated hourly precipitation. "
                "Timestamps are shifted back by 1 hour and daily maximum "
                "accumulation is used; converted from m to mm."
            ),
        },
        "wind_max": {
            "long_name": "Daily maximum 10m wind speed",
            "units": "m/s",
            "note": (
                "Computed hourly as sqrt(u10^2 + v10^2) from 10m u and v "
                "wind components, then aggregated to daily maximum."
            ),
        },
    }

    for var, attrs in meta.items():
        if var in ds:
            ds[var].attrs.update(attrs)

    ds.attrs.update(
        {
            "title": f"ERA5-Land daily aggregated climate data for {region}",
            "source": "ERA5-Land hourly data from CDS",
            "region": region,
            "cds_area_north_west_south_east": str(area),
            "aggregation_note": (
                "Temperature aggregated to daily min/mean/max. Relative "
                "humidity and specific humidity computed hourly and then "
                "averaged daily. Snow water equivalent averaged daily. "
                "Precipitation computed from ERA5-Land accumulated field using "
                "timestamp shift and daily maximum accumulation. Wind speed "
                "computed hourly from u10/v10 and aggregated to daily maximum."
            ),
        }
    )

    return ds


def compression_encoding(ds: xr.Dataset) -> dict:
    """NetCDF compression settings.

    Compression keeps files manageable without changing the daily values.
    """
    return {
        var: {
            "zlib": True,
            "complevel": 4,
            "dtype": "float32",
        }
        for var in ds.data_vars
    }


# =============================================================================
# 6. CDS retrieval with retry logic
# =============================================================================

def retrieve_with_retry(
    client,
    dataset,
    request,
    target,
    max_retries=5,
    wait_seconds=180,
):
    """Retrieve a CDS request with retries and partial-file cleanup."""

    target = Path(target)
    last_exc = None

    for attempt in range(1, max_retries + 1):
        try:
            if target.exists():
                target.unlink()

            print(
                f"CDS request attempt {attempt}/{max_retries} -> {target.name}",
                flush=True,
            )

            client.retrieve(dataset, request, str(target))
            return

        except Exception as e:
            last_exc = e
            print(f"Request failed on attempt {attempt}: {e}", flush=True)

            if target.exists():
                try:
                    target.unlink()
                except Exception:
                    pass

            if attempt < max_retries:
                sleep_time = wait_seconds * attempt
                print(f"Sleeping {sleep_time} seconds before retry...", flush=True)
                time.sleep(sleep_time)

    raise last_exc


# =============================================================================
# 7. Main workflow
# =============================================================================

def main():
    args = parse_args()

    year = args.year
    month = args.month
    region = args.region.lower()
    area = load_region_area(region, args.bbox_file)

    data_root = Path(args.data_root)
    scratch_root = Path(args.scratch_root)

    # -------------------------------------------------------------------------
    # 7.1 Calendar setup
    # -------------------------------------------------------------------------

    days_in_month = calendar.monthrange(year, month)[1]

    if month == 12:
        next_year = year + 1
        next_month = 1
    else:
        next_year = year
        next_month = month + 1

    month_start = np.datetime64(f"{year}-{month:02d}-01")
    month_end = np.datetime64(f"{year}-{month:02d}-{days_in_month:02d}")

    # -------------------------------------------------------------------------
    # 7.2 Output paths
    # -------------------------------------------------------------------------

    final_dir = data_root / "processed" / "daily" / region / f"{year}"
    final_dir.mkdir(parents=True, exist_ok=True)

    final_daily_file = final_dir / f"era5land_daily_{region}_{year}_{month:02d}.nc"

    if final_daily_file.exists():
        print(f"Final output already exists, skipping: {final_daily_file}", flush=True)
        return

    month_scratch = scratch_root / f"era5land_{region}_{year}_{month:02d}"
    raw_dir = month_scratch / "raw"
    interm_dir = month_scratch / "intermediate"

    raw_dir.mkdir(parents=True, exist_ok=True)
    interm_dir.mkdir(parents=True, exist_ok=True)

    main_raw_file = raw_dir / f"era5land_hourly_{region}_{year}_{month:02d}.nc"
    buffer_raw_file = raw_dir / f"era5land_hourly_{region}_{year}_{month:02d}_buffer.nc"

    temp_daily_file = interm_dir / f"temp_daily_{region}_{year}_{month:02d}.nc"
    humidity_daily_file = interm_dir / f"humidity_daily_{region}_{year}_{month:02d}.nc"
    snow_daily_file = interm_dir / f"snow_daily_{region}_{year}_{month:02d}.nc"
    precip_daily_file = interm_dir / f"precip_daily_{region}_{year}_{month:02d}.nc"
    wind_daily_file = interm_dir / f"wind_daily_{region}_{year}_{month:02d}.nc"

    final_tmp_file = month_scratch / f"era5land_daily_{region}_{year}_{month:02d}.nc"

    # -------------------------------------------------------------------------
    # 7.3 CDS requests
    # -------------------------------------------------------------------------

    main_request = {
        "variable": RAW_VARIABLES,
        "year": [str(year)],
        "month": [f"{month:02d}"],
        "day": [f"{d:02d}" for d in range(1, days_in_month + 1)],
        "time": [f"{h:02d}:00" for h in range(24)],
        "area": area,
        "data_format": "netcdf",
        "download_format": "unarchived",
    }

    buffer_request = {
        "variable": RAW_VARIABLES,
        "year": [str(next_year)],
        "month": [f"{next_month:02d}"],
        "day": ["01"],
        "time": ["00:00"],
        "area": area,
        "data_format": "netcdf",
        "download_format": "unarchived",
    }

    # -------------------------------------------------------------------------
    # 7.4 Start logging
    # -------------------------------------------------------------------------

    t0 = time.time()
    client = cdsapi.Client()

    print("===== ERA5-LAND REGIONAL MONTHLY WORKFLOW =====", flush=True)
    print(f"Region: {region}", flush=True)
    print(f"Year-month: {year}-{month:02d}", flush=True)
    print(f"Bbox file: {args.bbox_file}", flush=True)
    print(f"CDS area [north, west, south, east]: {area}", flush=True)
    print(f"Requested variables: {RAW_VARIABLES}", flush=True)
    print(f"Scratch workspace: {month_scratch}", flush=True)
    print(f"Final output: {final_daily_file}", flush=True)
    print("================================================", flush=True)

    # -------------------------------------------------------------------------
    # 7.5 Download hourly ERA5-Land files
    # -------------------------------------------------------------------------

    t_download_start = time.time()

    retrieve_with_retry(
        client,
        CDS_DATASET,
        main_request,
        main_raw_file,
        max_retries=args.max_retries,
        wait_seconds=args.retry_wait_seconds,
    )

    retrieve_with_retry(
        client,
        CDS_DATASET,
        buffer_request,
        buffer_raw_file,
        max_retries=args.max_retries,
        wait_seconds=args.retry_wait_seconds,
    )

    t_download_end = time.time()
    print(
        f"Download time: {(t_download_end - t_download_start) / 60:.2f} minutes",
        flush=True,
    )

    # -------------------------------------------------------------------------
    # 7.6 Open and concatenate main + buffer
    # -------------------------------------------------------------------------

    print("Opening raw datasets with chunks...", flush=True)
    t_open_start = time.time()

    ds_main = xr.open_dataset(main_raw_file).chunk({"valid_time": 24})
    ds_buffer = xr.open_dataset(buffer_raw_file).chunk({"valid_time": 1})
    ds = xr.concat([ds_main, ds_buffer], dim="valid_time")

    t_open_end = time.time()
    print(f"Open/concat time: {t_open_end - t_open_start:.2f} seconds", flush=True)

    # -------------------------------------------------------------------------
    # 7.7 Temperature block
    # -------------------------------------------------------------------------

    print("Aggregating temperature block...", flush=True)
    t_temp_start = time.time()

    t2m_c = ds["t2m"] - 273.15

    temp_daily = xr.Dataset(
        {
            "tmin": t2m_c.resample(valid_time="1D").min(),
            "tmean": t2m_c.resample(valid_time="1D").mean(),
            "tmax": t2m_c.resample(valid_time="1D").max(),
        }
    )

    temp_daily = temp_daily.sel(valid_time=slice(month_start, month_end))
    temp_daily.to_netcdf(temp_daily_file)

    del temp_daily

    t_temp_end = time.time()
    print(
        f"Temperature block time: {(t_temp_end - t_temp_start) / 60:.2f} minutes",
        flush=True,
    )

    # -------------------------------------------------------------------------
    # 7.8 Humidity block
    # -------------------------------------------------------------------------

    print("Computing and aggregating humidity block...", flush=True)
    t_humidity_start = time.time()

    # Relative humidity and specific humidity are not downloaded directly here.
    # They are computed hourly from temperature, dew point, and surface pressure,
    # then averaged to daily values.
    d2m_c = ds["d2m"] - 273.15
    sp_pa = ds["sp"]

    rh = compute_relative_humidity(t2m_c, d2m_c)
    q_gkg = compute_specific_humidity_gkg(d2m_c, sp_pa)

    humidity_daily = xr.Dataset(
        {
            "rh_mean": rh.resample(valid_time="1D").mean(),
            "q_mean": q_gkg.resample(valid_time="1D").mean(),
        }
    )

    humidity_daily = humidity_daily.sel(valid_time=slice(month_start, month_end))
    humidity_daily.to_netcdf(humidity_daily_file)

    del d2m_c, sp_pa, rh, q_gkg, humidity_daily, t2m_c

    t_humidity_end = time.time()
    print(
        f"Humidity block time: {(t_humidity_end - t_humidity_start) / 60:.2f} minutes",
        flush=True,
    )

    # -------------------------------------------------------------------------
    # 7.9 Snow water equivalent block
    # -------------------------------------------------------------------------

    print("Aggregating snow water equivalent block...", flush=True)
    t_snow_start = time.time()

    snow_daily = xr.Dataset(
        {
            "swe_mean": ds["sd"].resample(valid_time="1D").mean() * 1000.0,
        }
    )

    snow_daily = snow_daily.sel(valid_time=slice(month_start, month_end))
    snow_daily.to_netcdf(snow_daily_file)

    del snow_daily

    t_snow_end = time.time()
    print(
        f"Snow block time: {(t_snow_end - t_snow_start) / 60:.2f} minutes",
        flush=True,
    )

    # -------------------------------------------------------------------------
    # 7.10 Precipitation block
    # -------------------------------------------------------------------------

    print("Aggregating precipitation block using ERA5-Land accumulation logic...", flush=True)
    t_precip_start = time.time()

    # ERA5-Land precipitation is accumulated. The midnight value belongs to the
    # day that just ended, so shift timestamps back before making daily totals.
    tp_shifted = ds["tp"].assign_coords(
        valid_time=ds["valid_time"] - np.timedelta64(1, "h")
    )

    precip_daily = (
        tp_shifted.resample(valid_time="1D").max() * 1000.0
    ).to_dataset(name="tp_total")

    precip_daily = precip_daily.sel(valid_time=slice(month_start, month_end))
    precip_daily.to_netcdf(precip_daily_file)

    del tp_shifted, precip_daily

    t_precip_end = time.time()
    print(
        f"Precipitation block time: {(t_precip_end - t_precip_start) / 60:.2f} minutes",
        flush=True,
    )

    # -------------------------------------------------------------------------
    # 7.11 Wind speed block
    # -------------------------------------------------------------------------

    print("Computing and aggregating wind speed block...", flush=True)
    t_wind_start = time.time()

    # Wind speed is not stored directly in hourly data. Compute it from the 10m u
    # and v wind components, then keep the daily maximum.
    wind_speed = np.sqrt(ds["u10"] ** 2 + ds["v10"] ** 2)

    wind_daily = xr.Dataset(
        {
            "wind_max": wind_speed.resample(valid_time="1D").max(),
        }
    )

    wind_daily = wind_daily.sel(valid_time=slice(month_start, month_end))
    wind_daily.to_netcdf(wind_daily_file)

    del wind_speed, wind_daily

    t_wind_end = time.time()
    print(
        f"Wind block time: {(t_wind_end - t_wind_start) / 60:.2f} minutes",
        flush=True,
    )

    ds.close()
    ds_main.close()
    ds_buffer.close()

    # -------------------------------------------------------------------------
    # 7.12 Merge final daily dataset
    # -------------------------------------------------------------------------

    print("Merging daily outputs...", flush=True)
    t_merge_start = time.time()

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

    # -------------------------------------------------------------------------
    # 7.13 Cleanup and summary
    # -------------------------------------------------------------------------

    main_raw_size_gb = (
        main_raw_file.stat().st_size / 1024**3 if main_raw_file.exists() else 0
    )
    buffer_raw_size_gb = (
        buffer_raw_file.stat().st_size / 1024**3 if buffer_raw_file.exists() else 0
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
    print(f"CDS area:                 {area}", flush=True)
    print(f"Main raw file size:        {main_raw_size_gb:.2f} GB", flush=True)
    print(f"Buffer raw file size:      {buffer_raw_size_gb:.4f} GB", flush=True)
    print(f"Final daily file size:     {final_daily_size_gb:.2f} GB", flush=True)
    print(f"Download time:             {(t_download_end - t_download_start) / 60:.2f} min", flush=True)
    print(f"Temperature block time:    {(t_temp_end - t_temp_start) / 60:.2f} min", flush=True)
    print(f"Humidity block time:       {(t_humidity_end - t_humidity_start) / 60:.2f} min", flush=True)
    print(f"Snow block time:           {(t_snow_end - t_snow_start) / 60:.2f} min", flush=True)
    print(f"Precipitation block time:  {(t_precip_end - t_precip_start) / 60:.2f} min", flush=True)
    print(f"Wind block time:           {(t_wind_end - t_wind_start) / 60:.2f} min", flush=True)
    print(f"Merge/save final time:     {(t_merge_end - t_merge_start) / 60:.2f} min", flush=True)
    print(f"Total runtime:             {(t1 - t0) / 60:.2f} min", flush=True)


if __name__ == "__main__":
    main()
