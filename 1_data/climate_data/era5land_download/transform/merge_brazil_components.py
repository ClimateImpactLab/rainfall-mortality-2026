#!/usr/bin/env python3
"""Build the Brazil ERA5-Land raster used by the mortality aggregation.

Inputs are annual, single-variable ERA5-Land files in the raw/daily tree:

* ``latam``: the main Latin America raster.
* ``brazil_east``: a narrow coastal extension for eastern Brazil.

The output region is named ``brazil``.  The script keeps the full LATAM grid and
appends only the new Brazil-east longitude columns east of the LATAM edge.  For
those appended longitudes, values are filled only on the latitude rows covered
by the Brazil-east extension.  The rest of the appended cells stay missing.

No interpolation, averaging, or regridding is performed.

Why this exists
---------------
The LATAM box was intended to cover Latin America, but the eastern edge missed
a small part of Brazil. That showed up during Brazil climate aggregation. The
`brazil_east` patch was downloaded from the affected Brazil ADM2 units and is
merged here with the LATAM raster.

Inputs
------
Annual single-variable files in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/{latam,brazil_east}/<variable>/

Output
------
One annual single-variable file in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/brazil/<variable>/

Rerun notes
-----------
Safe to rerun if the output is absent. Existing outputs are skipped unless
`--overwrite` is used. This script scans and writes NetCDF files, so run batches
on a compute node.
"""

from __future__ import annotations

import argparse
import calendar
import os
import resource
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import xarray as xr


# =============================================================================
# 1. Constants
# =============================================================================

VARIABLES = (
    "q_mean",
    "rh_mean",
    "swe_mean",
    "tmax",
    "tmean",
    "tmin",
    "tp_total",
    "wind_max",
)
YEAR_MIN = 1997
YEAR_MAX = 2024
DEFAULT_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily")
EXPECTED_DIMS = ("valid_time", "latitude", "longitude")
OUTPUT_CHUNKS = (31, 142, 253)
GRID_SCALE = 10
GRID_FLOAT_TOLERANCE = 1e-8


# =============================================================================
# 2. Arguments and Paths
# =============================================================================

class ValidationError(RuntimeError):
    """A file or source pair failed a required validation."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variable", required=True, choices=VARIABLES)
    parser.add_argument("--year", required=True, type=int, choices=range(YEAR_MIN, YEAR_MAX + 1))
    parser.add_argument("--input-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-region", default="brazil")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--check-only", action="store_true")
    return parser.parse_args()


def source_path(root: Path, region: str, variable: str, year: int) -> Path:
    return root / region / variable / f"era5land_{region}_{variable}_{year}.nc4"


def output_path(root: Path, region: str, variable: str, year: int) -> Path:
    return root / region / variable / f"era5land_{region}_{variable}_{year}.nc4"


def temporary_path(final_path: Path) -> Path:
    return final_path.with_suffix(".tmp.nc4")


def expected_days(year: int) -> int:
    return 366 if calendar.isleap(year) else 365


def _fail(message: str) -> None:
    raise ValidationError(message)


def _require(condition: bool, message: str) -> None:
    if not condition:
        _fail(message)


# =============================================================================
# 3. Source Validation
# =============================================================================

def _grid_in_tenths(values: np.ndarray, name: str) -> np.ndarray:
    """Represent 0.1-degree coordinates as integer tenths for exact checks."""
    values = np.asarray(values)
    _require(values.ndim == 1, f"{name} must be one-dimensional")
    scaled = values.astype(np.float64) * GRID_SCALE
    integer = np.rint(scaled).astype(np.int64)
    residual = np.abs(scaled - integer)
    _require(
        bool(np.all(residual <= GRID_FLOAT_TOLERANCE * GRID_SCALE)),
        f"{name} contains a coordinate that is not on the 0.1-degree grid; "
        f"maximum residual={residual.max() / GRID_SCALE:.3g} degrees",
    )
    return integer


def _validate_daily_time(values: np.ndarray, year: int, label: str) -> None:
    """Require one midnight timestamp for every day in the requested year."""
    values = np.asarray(values)
    n_days = expected_days(year)
    _require(values.ndim == 1, f"{label}: valid_time must be one-dimensional")
    _require(len(values) == n_days, f"{label}: expected {n_days} days, found {len(values)}")
    expected = np.arange(
        np.datetime64(f"{year}-01-01"),
        np.datetime64(f"{year + 1}-01-01"),
        dtype="datetime64[D]",
    )
    actual_days = values.astype("datetime64[D]")
    actual_ns = values.astype("datetime64[ns]")
    _require(np.array_equal(actual_days, expected), f"{label}: valid_time is not complete for {year}")
    _require(
        np.array_equal(actual_ns, expected.astype("datetime64[ns]")),
        f"{label}: valid_time values are not daily midnight timestamps",
    )


def _validate_regular_grid(ds: xr.Dataset, label: str) -> tuple[np.ndarray, np.ndarray]:
    """Require a regular 0.1-degree ERA5-Land grid."""
    lat10 = _grid_in_tenths(ds.latitude.values, f"{label} latitude")
    lon10 = _grid_in_tenths(ds.longitude.values, f"{label} longitude")
    _require(np.array_equal(np.diff(lat10), -np.ones(len(lat10) - 1, dtype=np.int64)), f"{label}: latitude is not -0.1")
    _require(np.array_equal(np.diff(lon10), np.ones(len(lon10) - 1, dtype=np.int64)), f"{label}: longitude is not +0.1")
    return lat10, lon10


def open_and_validate_source(path: Path, region: str, variable: str, year: int) -> xr.Dataset:
    label = f"{region} source {path}"
    if path.name.endswith(".tmp.nc4") or ".tmp." in path.name:
        _fail(f"{label}: temporary inputs are not permitted")
    if not path.is_file():
        raise FileNotFoundError(f"Missing final {region} input: {path}")
    try:
        ds = xr.open_dataset(
            path,
            engine="netcdf4",
            chunks={},
            decode_times=xr.coders.CFDatetimeCoder(use_cftime=False),
        )
    except Exception as exc:
        _fail(f"{label}: cannot open successfully: {type(exc).__name__}: {exc}")
    try:
        _require(variable in ds.data_vars, f"{label}: requested variable {variable!r} is absent")
        var = ds[variable]
        _require(var.dims == EXPECTED_DIMS, f"{label}: dimensions are {var.dims}, expected {EXPECTED_DIMS}")
        _require(np.dtype(var.dtype) == np.dtype("float32"), f"{label}: dtype is {var.dtype}, expected float32")
        _require("units" in var.attrs and str(var.attrs["units"]).strip(), f"{label}: variable units are absent")
        for coord in EXPECTED_DIMS:
            _require(coord in ds.coords, f"{label}: coordinate {coord!r} is absent")
        _validate_daily_time(ds.valid_time.values, year, label)
        _validate_regular_grid(ds, label)
    except Exception:
        ds.close()
        raise
    return ds


def validate_source_pair(latam: xr.Dataset, east: xr.Dataset, variable: str, year: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Check that the two sources can be joined without resampling."""
    _require(np.array_equal(latam.valid_time.values, east.valid_time.values), "LATAM and Brazil-east time coordinates differ")
    _require(latam[variable].attrs.get("units") == east[variable].attrs.get("units"), "LATAM and Brazil-east units differ")
    _require(latam[variable].dtype == east[variable].dtype, "LATAM and Brazil-east dtypes differ")
    latam_lat10, latam_lon10 = _validate_regular_grid(latam, "LATAM")
    east_lat10, east_lon10 = _validate_regular_grid(east, "Brazil-east")

    latam_lat_set = set(latam_lat10.tolist())
    missing_lats = [lat for lat in east_lat10.tolist() if lat not in latam_lat_set]
    _require(not missing_lats, f"Brazil-east has latitude rows absent from LATAM: {missing_lats}")

    new_east_lon10 = east_lon10[east_lon10 > latam_lon10[-1]]
    _require(len(new_east_lon10) > 0, "Brazil-east contributes no new longitudes east of LATAM")
    _require(
        np.array_equal(new_east_lon10, np.arange(latam_lon10[-1] + 1, east_lon10[-1] + 1, dtype=np.int64)),
        "New Brazil-east longitude columns are not contiguous with LATAM",
    )
    _require(east_lon10[-1] > latam_lon10[-1], "Brazil-east does not extend east of LATAM")
    _validate_daily_time(latam.valid_time.values, year, "source pair")
    return latam_lat10, latam_lon10, new_east_lon10


# =============================================================================
# 4. Dataset Construction
# =============================================================================

def _clean_source(ds: xr.Dataset, variable: str) -> xr.Dataset:
    """Drop non-dimensional coordinates and retain only the requested variable."""
    data = ds[variable].reset_coords(drop=True)
    coords = {
        "valid_time": ("valid_time", ds.valid_time.values, dict(ds.valid_time.attrs)),
        "latitude": ("latitude", ds.latitude.values, dict(ds.latitude.attrs)),
        "longitude": ("longitude", ds.longitude.values, dict(ds.longitude.attrs)),
    }
    return xr.Dataset(
        data_vars={variable: (EXPECTED_DIMS, data.data, dict(data.attrs))},
        coords=coords,
    )


def build_east_extension(
    latam: xr.Dataset,
    east: xr.Dataset,
    variable: str,
    latam_lat10: np.ndarray,
    new_east_lon10: np.ndarray,
) -> xr.Dataset:
    """Create the appended east block on the LATAM latitude grid.

    The patch does not cover every LATAM latitude row. Rows outside the patch
    stay missing in the appended longitudes.
    """
    east_lat10 = _grid_in_tenths(east.latitude.values, "Brazil-east latitude")
    east_lon10 = _grid_in_tenths(east.longitude.values, "Brazil-east longitude")
    east_lon_positions = [int(np.where(east_lon10 == lon)[0][0]) for lon in new_east_lon10]
    latam_lat_index = {int(lat): i for i, lat in enumerate(latam_lat10)}
    east_target_rows = [latam_lat_index[int(lat)] for lat in east_lat10]

    shape = (
        latam.sizes["valid_time"],
        latam.sizes["latitude"],
        len(new_east_lon10),
    )
    full = np.full(shape, np.nan, dtype=np.float32)
    subset = east[variable].isel(longitude=east_lon_positions).values.astype(np.float32, copy=False)
    full[:, east_target_rows, :] = subset

    coords = {
        "valid_time": ("valid_time", latam.valid_time.values, dict(latam.valid_time.attrs)),
        "latitude": ("latitude", latam.latitude.values, dict(latam.latitude.attrs)),
        "longitude": (
            "longitude",
            new_east_lon10.astype(np.float64) / GRID_SCALE,
            dict(latam.longitude.attrs),
        ),
    }
    return xr.Dataset(
        data_vars={variable: (EXPECTED_DIMS, full, dict(east[variable].attrs))},
        coords=coords,
    )


def build_combined(
    latam: xr.Dataset,
    east: xr.Dataset,
    variable: str,
    year: int,
    output_region: str,
    latam_path: Path,
    east_path: Path,
    latam_lat10: np.ndarray,
    new_east_lon10: np.ndarray,
) -> xr.Dataset:
    """Concatenate LATAM with the appended Brazil-east longitude columns."""
    east_extension = build_east_extension(latam, east, variable, latam_lat10, new_east_lon10)
    combined = xr.concat(
        [_clean_source(latam, variable), east_extension],
        dim="longitude",
        data_vars="minimal",
        coords="minimal",
        compat="equals",
        join="exact",
    ).chunk(dict(zip(EXPECTED_DIMS, OUTPUT_CHUNKS)))

    combined[variable].attrs = dict(latam[variable].attrs)
    combined.attrs = {
        "title": f"ERA5-Land daily {variable} for {output_region}, {year}",
        "region": output_region,
        "year": str(year),
        "variable": variable,
        "source_regions": "latam; brazil_east",
        "latam_source_file": str(latam_path),
        "brazil_east_source_file": str(east_path),
        "source_files": f"{latam_path}; {east_path}",
        "latitude_bounds": f"{float(combined.latitude.values[0])}; {float(combined.latitude.values[-1])} (descending)",
        "longitude_bounds": f"{float(combined.longitude.values[0])}; {float(combined.longitude.values[-1])} (increasing)",
        "appended_longitudes": "; ".join(f"{lon / GRID_SCALE:.1f}" for lon in new_east_lon10),
        "creation_timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "combination_method": "The full LATAM grid was retained and Brazil-east longitudes east of LATAM were appended.",
        "spatial_processing": "No interpolation, averaging, or regridding was performed.",
        "file_structure": "Annual single-variable daily file.",
    }
    return combined


# =============================================================================
# 5. Writing and Main
# =============================================================================

def output_encoding(variable: str) -> dict:
    return {
        variable: {
            "dtype": "float32",
            "_FillValue": np.float32(np.nan),
            "zlib": True,
            "shuffle": True,
            "complevel": 4,
            "chunksizes": OUTPUT_CHUNKS,
        }
    }


def memory_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0


def main() -> int:
    args = parse_args()
    variable = args.variable
    year = args.year
    latam_path = source_path(args.input_root, "latam", variable, year)
    east_path = source_path(args.input_root, "brazil_east", variable, year)
    final_path = output_path(args.output_root, args.output_region, variable, year)
    tmp_path = temporary_path(final_path)

    print(f"start={datetime.now(timezone.utc).isoformat()} variable={variable} year={year}", flush=True)
    print(f"latam_path={latam_path}", flush=True)
    print(f"brazil_east_path={east_path}", flush=True)
    print(f"output_path={final_path}", flush=True)

    if final_path.exists() and not args.overwrite:
        print("output_exists_skip=true", flush=True)
        return 0
    if tmp_path.exists():
        tmp_path.unlink()

    try:
        latam = open_and_validate_source(latam_path, "latam", variable, year)
        east = open_and_validate_source(east_path, "brazil_east", variable, year)
    except FileNotFoundError as exc:
        print(f"source_pair_not_ready=true reason={exc}", flush=True)
        return 3
    try:
        latam_lat10, latam_lon10, new_east_lon10 = validate_source_pair(latam, east, variable, year)
        print(
            "source_grids="
            f"latam_lat={latam.sizes['latitude']} latam_lon={latam.sizes['longitude']} "
            f"east_lat={east.sizes['latitude']} east_lon={east.sizes['longitude']} "
            f"new_lon_count={len(new_east_lon10)}",
            flush=True,
        )
        combined = build_combined(
            latam,
            east,
            variable,
            year,
            args.output_region,
            latam_path,
            east_path,
            latam_lat10,
            new_east_lon10,
        )
        print(f"combined_sizes={dict(combined.sizes)}", flush=True)
        if not args.check_only:
            final_path.parent.mkdir(parents=True, exist_ok=True)
            t0 = time.time()
            combined.to_netcdf(tmp_path, engine="netcdf4", encoding=output_encoding(variable), compute=True)
            os.replace(tmp_path, final_path)
            print(f"write_seconds={time.time() - t0:.1f} output_bytes={final_path.stat().st_size}", flush=True)
        combined.close()
    finally:
        latam.close()
        east.close()

    print(f"max_rss_mb={memory_mb():.1f}", flush=True)
    print(f"end={datetime.now(timezone.utc).isoformat()}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"VALIDATION_ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(2)
