#!/usr/bin/env python3
"""
convert_monthly_to_annual_by_variable.py

Purpose
-------
Convert ERA5-Land monthly multi-variable daily files into annual
single-variable files, including wind_max.

Why this exists
---------------
The download scripts save one file per region-month with all variables in the
same file. The final daily climate directory is organized the other way around:
one region, one variable, and one year per file. This script does that reshaping.

Input layout
------------
/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily/
    <region>/<year>/era5land_daily_<region>_<year>_<month>.nc

Example
-------
/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily/
    europe/1950/era5land_daily_europe_1950_01.nc

Output layout
-------------
/project/cil/gcp/climate/ERA5-LAND/raw/daily/
    <region>/<variable>/era5land_<region>_<variable>_<year>.nc4

Each output file contains one variable for one region-year.

Rerun notes
-----------
Safe to rerun if the output files are absent. Existing files are skipped unless
`--overwrite` is used. This opens 12 monthly NetCDF files and writes 8 annual
files, so run year batches on a compute node.
"""

# =============================================================================
# 0. Imports
# =============================================================================

import argparse
from pathlib import Path

import xarray as xr


# =============================================================================
# 1. Constants
# =============================================================================

DEFAULT_INPUT_ROOT = Path(
    "/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily"
)

DEFAULT_OUTPUT_ROOT = Path(
    "/project/cil/gcp/climate/ERA5-LAND/raw/daily"
)

VARIABLES = [
    "tmin",
    "tmean",
    "tmax",
    "rh_mean",
    "q_mean",
    "swe_mean",
    "tp_total",
    "wind_max",
]


# =============================================================================
# 2. Arguments
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--region",
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

    parser.add_argument("--year", required=True, type=int)

    parser.add_argument(
        "--input-root",
        type=Path,
        default=DEFAULT_INPUT_ROOT,
    )

    parser.add_argument(
        "--output-root",
        type=Path,
        default=DEFAULT_OUTPUT_ROOT,
    )

    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing annual variable files.",
    )

    return parser.parse_args()


# =============================================================================
# 3. Helpers
# =============================================================================

def expected_monthly_files(input_root: Path, region: str, year: int):
    files = []

    for month in range(1, 13):
        f = (
            input_root
            / region
            / f"{year}"
            / f"era5land_daily_{region}_{year}_{month:02d}.nc"
        )
        files.append(f)

    return files


def check_monthly_files(files):
    missing = [f for f in files if not f.exists()]

    if missing:
        msg = "\n".join(str(f) for f in missing)
        raise FileNotFoundError(f"Missing monthly files:\n{msg}")


def compression_encoding(ds: xr.Dataset):
    """Use compression for annual NetCDF outputs."""
    return {
        var: {
            "zlib": True,
            "complevel": 4,
            "dtype": "float32",
        }
        for var in ds.data_vars
    }


def clean_variable_attrs(ds_var: xr.Dataset, var: str, region: str, year: int, source_files):
    """Keep each annual variable file self-describing."""
    source = str(
        ds_var.attrs.get(
            "source",
            "ERA5-Land hourly data from CDS/DestinE, aggregated to daily",
        )
    )
    var_meta = {
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

    if var in ds_var and var in var_meta:
        ds_var[var].attrs.update(var_meta[var])

    ds_var.attrs.update(
        {
            "title": f"ERA5-Land daily {var} data for {region}, {year}",
            "source": source,
            "region": region,
            "year": str(year),
            "variable": var,
            "input_files": "; ".join(str(f) for f in source_files),
            "file_structure": "Annual single-variable file created from monthly daily files.",
        }
    )

    return ds_var


# =============================================================================
# 4. Main
# =============================================================================

def main():
    args = parse_args()

    region = args.region
    year = args.year
    input_root = args.input_root
    output_root = args.output_root

    print("=" * 80, flush=True)
    print(f"Converting region-year: {region} {year}", flush=True)
    print(f"Input root:  {input_root}", flush=True)
    print(f"Output root: {output_root}", flush=True)
    print(f"Variables:   {VARIABLES}", flush=True)
    print("=" * 80, flush=True)

    monthly_files = expected_monthly_files(input_root, region, year)
    check_monthly_files(monthly_files)

    print("Monthly files:", flush=True)
    for f in monthly_files:
        print(f"  {f}", flush=True)

    # -------------------------------------------------------------------------
    # 4.1 Open and combine monthly files
    # -------------------------------------------------------------------------

    print("Opening monthly files with xarray...", flush=True)

    ds = xr.open_mfdataset(
        [str(f) for f in monthly_files],
        combine="by_coords",
        parallel=False,
        chunks={"valid_time": 31},
    )

    ds = ds.sortby("valid_time")

    print(f"Available variables: {list(ds.data_vars)}", flush=True)

    n_days = ds.sizes["valid_time"]
    print(f"Combined dataset has {n_days} days", flush=True)
    print(
        f"Time range: {ds.valid_time.min().values} to {ds.valid_time.max().values}",
        flush=True,
    )

    # Basic year check
    years_found = set(ds.valid_time.dt.strftime("%Y").values)

    if years_found != {str(year)}:
        raise ValueError(f"Unexpected years in combined dataset: {years_found}")

    # -------------------------------------------------------------------------
    # 4.2 Save one annual file per variable
    # -------------------------------------------------------------------------

    # Fail before writing anything if one of the expected daily variables is not
    # present in the monthly files.
    missing_vars = [var for var in VARIABLES if var not in ds.data_vars]

    if missing_vars:
        raise ValueError(
            f"Missing expected variables: {missing_vars}. "
            f"Available variables: {list(ds.data_vars)}"
        )

    for var in VARIABLES:
        out_dir = output_root / region / var
        out_dir.mkdir(parents=True, exist_ok=True)

        out_file = out_dir / f"era5land_{region}_{var}_{year}.nc4"

        if out_file.exists() and not args.overwrite:
            print(f"Output exists, skipping: {out_file}", flush=True)
            continue

        tmp_file = out_file.with_suffix(".tmp.nc4")

        if tmp_file.exists():
            tmp_file.unlink()

        print(f"Writing {var} -> {out_file}", flush=True)

        ds_var = ds[[var]]
        ds_var = clean_variable_attrs(ds_var, var, region, year, monthly_files)

        encoding = compression_encoding(ds_var)
        ds_var.to_netcdf(tmp_file, encoding=encoding)

        tmp_file.rename(out_file)

    ds.close()

    print("Done.", flush=True)


if __name__ == "__main__":
    main()
