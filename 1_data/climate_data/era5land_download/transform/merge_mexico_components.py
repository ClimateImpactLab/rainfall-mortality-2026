#!/usr/bin/env python3
"""Combine USA and Mexico-south ERA5-Land annual daily files by latitude.

The output region is named ``mexico`` because this domain is intended for
Mexico admin aggregation: the existing USA extract covers Mexico down through
15.0N, and the Mexico-south strip adds 14.9N through 14.5N.  No interpolation,
averaging, or regridding is performed.

Why this exists
---------------
The USA download box was built for the USA plus relevant HydroBASINS areas. It
also covered most of Mexico, but not the southern edge. The separate
`mexico_south` strip fills that missing edge. This script joins the two pieces
into the final `mexico` folder.

Inputs
------
Annual single-variable files in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/{usa,mexico_south}/<variable>/

Output
------
One annual single-variable file in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/mexico/<variable>/

Rerun notes
-----------
Safe to rerun if the output is absent. Existing outputs are validated and
skipped unless `--overwrite` is used. This script scans and writes NetCDF files,
so run batches on a compute node.
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

import dask.array as da
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
YEAR_MIN = 1990
YEAR_MAX = 2024
DEFAULT_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily")
EXPECTED_DIMS = ("valid_time", "latitude", "longitude")
EXPECTED_USA_LATITUDE_COUNT = 564
EXPECTED_SOUTH_LATITUDE_COUNT = 5
EXPECTED_LATITUDE_COUNT = 569
EXPECTED_LONGITUDE_COUNT = 1265
OUTPUT_CHUNKS = (31, 142, 253)
GRID_SCALE = 10
GRID_FLOAT_TOLERANCE = 1e-8


class ValidationError(RuntimeError):
    """A file or source pair failed a required validation."""


# =============================================================================
# 2. Arguments and Paths
# =============================================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variable", required=True, choices=VARIABLES)
    parser.add_argument("--year", required=True, type=int, choices=range(YEAR_MIN, YEAR_MAX + 1))
    parser.add_argument("--input-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output-region", default="mexico")
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


# =============================================================================
# 3. Validation Helpers
# =============================================================================

def _fail(message: str) -> None:
    raise ValidationError(message)


def _require(condition: bool, message: str) -> None:
    if not condition:
        _fail(message)


def _grid_in_tenths(values: np.ndarray, name: str) -> np.ndarray:
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
    values = np.asarray(values)
    n_days = expected_days(year)
    _require(values.ndim == 1, f"{label}: valid_time must be one-dimensional")
    _require(len(values) == n_days, f"{label}: expected {n_days} days, found {len(values)}")
    expected = np.arange(
        np.datetime64(f"{year}-01-01"),
        np.datetime64(f"{year + 1}-01-01"),
        dtype="datetime64[D]",
    )
    try:
        actual_days = values.astype("datetime64[D]")
        actual_ns = values.astype("datetime64[ns]")
    except (TypeError, ValueError) as exc:
        _fail(f"{label}: valid_time is not a decoded datetime coordinate: {exc}")
    _require(np.array_equal(actual_days, expected), f"{label}: valid_time is not complete for {year}")
    _require(
        np.array_equal(actual_ns, expected.astype("datetime64[ns]")),
        f"{label}: valid_time values are not daily midnight timestamps",
    )


def _validate_coordinate_geometry(ds: xr.Dataset, region: str, label: str) -> None:
    lat10 = _grid_in_tenths(ds.latitude.values, f"{label} latitude")
    lon10 = _grid_in_tenths(ds.longitude.values, f"{label} longitude")
    _require(ds.sizes.get("longitude") == EXPECTED_LONGITUDE_COUNT, f"{label}: unexpected longitude count")
    _require((lon10[0], lon10[-1]) == (-1791, -527), f"{label}: longitude bounds are not -179.1 to -52.7")
    _require(np.array_equal(np.diff(lon10), np.ones(len(lon10) - 1, dtype=np.int64)), f"{label}: longitude is not +0.1")
    if region == "usa":
        _require(ds.sizes.get("latitude") == EXPECTED_USA_LATITUDE_COUNT, f"{label}: expected 564 USA latitude rows")
        _require((lat10[0], lat10[-1]) == (713, 150), f"{label}: USA latitude bounds are not 71.3 to 15.0")
    elif region == "mexico_south":
        _require(ds.sizes.get("latitude") == EXPECTED_SOUTH_LATITUDE_COUNT, f"{label}: expected 5 Mexico-south latitude rows")
        _require((lat10[0], lat10[-1]) == (149, 145), f"{label}: Mexico-south latitude bounds are not 14.9 to 14.5")
    else:
        _fail(f"{label}: unexpected region {region}")
    _require(np.array_equal(np.diff(lat10), -np.ones(len(lat10) - 1, dtype=np.int64)), f"{label}: latitude is not -0.1")


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
        _validate_coordinate_geometry(ds, region, label)
    except Exception:
        ds.close()
        raise
    return ds


def validate_source_pair(usa: xr.Dataset, south: xr.Dataset, variable: str, year: int) -> None:
    # The two files should have the same time and longitude grid, and the
    # Mexico-south rows should start exactly one 0.1-degree step below USA.
    _require(np.array_equal(usa.valid_time.values, south.valid_time.values), "USA and Mexico-south time coordinates differ")
    _require(usa[variable].attrs.get("units") == south[variable].attrs.get("units"), "USA and Mexico-south units differ")
    _require(usa[variable].dtype == south[variable].dtype, "USA and Mexico-south dtypes differ")
    usa_lon10 = _grid_in_tenths(usa.longitude.values, "USA longitude")
    south_lon10 = _grid_in_tenths(south.longitude.values, "Mexico-south longitude")
    _require(np.array_equal(usa_lon10, south_lon10), "USA and Mexico-south longitude grids differ")
    usa_lat10 = _grid_in_tenths(usa.latitude.values, "USA latitude")
    south_lat10 = _grid_in_tenths(south.latitude.values, "Mexico-south latitude")
    _require(usa_lat10[-1] - south_lat10[0] == 1, "Mexico-south does not start exactly one row below USA")
    combined10 = np.concatenate([usa_lat10, south_lat10])
    _require(len(np.unique(combined10)) == len(combined10), "Combined latitude has duplicates")
    _require(np.array_equal(np.diff(combined10), -np.ones(len(combined10) - 1, dtype=np.int64)), "Combined latitude is not uniformly -0.1")
    _require(len(combined10) == EXPECTED_LATITUDE_COUNT, "Combined latitude count is not 569")
    _validate_daily_time(usa.valid_time.values, year, "source pair")


def _clean_source(ds: xr.Dataset, variable: str, longitude: np.ndarray | None = None) -> xr.Dataset:
    data = ds[variable].reset_coords(drop=True)
    coords = {
        "valid_time": ("valid_time", ds.valid_time.values, dict(ds.valid_time.attrs)),
        "latitude": ("latitude", ds.latitude.values, dict(ds.latitude.attrs)),
        "longitude": ("longitude", ds.longitude.values if longitude is None else longitude, dict(ds.longitude.attrs)),
    }
    return xr.Dataset(
        data_vars={variable: (EXPECTED_DIMS, data.data, dict(data.attrs))},
        coords=coords,
    )


# =============================================================================
# 4. Dataset Construction
# =============================================================================

def build_combined(
    usa: xr.Dataset,
    south: xr.Dataset,
    variable: str,
    year: int,
    output_region: str,
    usa_path: Path,
    south_path: Path,
) -> xr.Dataset:
    combined = xr.concat(
        [_clean_source(usa, variable), _clean_source(south, variable, longitude=usa.longitude.values)],
        dim="latitude",
        data_vars="minimal",
        coords="minimal",
        compat="equals",
        join="exact",
    ).chunk(dict(zip(EXPECTED_DIMS, OUTPUT_CHUNKS)))

    attrs = dict(usa[variable].attrs)
    for key, value in {
        "GRIB_Ny": EXPECTED_LATITUDE_COUNT,
        "GRIB_numberOfPoints": EXPECTED_LATITUDE_COUNT * EXPECTED_LONGITUDE_COUNT,
        "GRIB_latitudeOfFirstGridPointInDegrees": 71.3,
        "GRIB_latitudeOfLastGridPointInDegrees": 14.5,
    }.items():
        if key in attrs:
            attrs[key] = value
    combined[variable].attrs = attrs
    combined.attrs = {
        "title": f"ERA5-Land daily {variable} for {output_region}, {year}",
        "region": output_region,
        "year": str(year),
        "variable": variable,
        "source_regions": "usa; mexico_south",
        "usa_source_file": str(usa_path),
        "mexico_south_source_file": str(south_path),
        "source_files": f"{usa_path}; {south_path}",
        "latitude_bounds": "71.3; 14.5 (descending)",
        "longitude_bounds": "-179.1; -52.7 (increasing)",
        "creation_timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "combination_method": "The USA and Mexico-south domains were directly concatenated by latitude.",
        "spatial_processing": "No interpolation, averaging, or regridding was performed.",
        "file_structure": "Annual single-variable daily file.",
    }
    return combined


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


# =============================================================================
# 5. Output Validation and Main
# =============================================================================

def _arrays_equal_with_nan(left: xr.DataArray, right: xr.DataArray) -> bool:
    left_data = left.data
    right_data = right.data
    equal = da.equal(left_data, right_data) | (da.isnan(left_data) & da.isnan(right_data))
    return bool(equal.all().compute(scheduler="threads", num_workers=2))


def validate_output(
    path: Path,
    usa: xr.Dataset,
    south: xr.Dataset,
    variable: str,
    year: int,
    output_region: str,
    full_values: bool = True,
) -> dict:
    label = f"output {path}"
    try:
        out = xr.open_dataset(
            path,
            engine="netcdf4",
            chunks={},
            decode_times=xr.coders.CFDatetimeCoder(use_cftime=False),
        )
    except Exception as exc:
        _fail(f"{label}: cannot open successfully: {type(exc).__name__}: {exc}")
    try:
        _require(list(out.data_vars) == [variable], f"{label}: unexpected data variables {list(out.data_vars)}")
        _require(out[variable].dims == EXPECTED_DIMS, f"{label}: incorrect dimensions {out[variable].dims}")
        _require(out.attrs.get("region") == output_region, f"{label}: incorrect region metadata")
        _require(str(out.attrs.get("year")) == str(year), f"{label}: incorrect year metadata")
        _require(out.attrs.get("variable") == variable, f"{label}: incorrect variable metadata")
        _require(out.attrs.get("source_regions") == "usa; mexico_south", f"{label}: incorrect source_regions metadata")
        _require(np.dtype(out[variable].dtype) == np.dtype("float32"), f"{label}: storage dtype is not float32")
        _require(out[variable].attrs.get("units") == usa[variable].attrs.get("units"), f"{label}: units differ from sources")
        _require(out.sizes.get("valid_time") == expected_days(year), f"{label}: incorrect day count")
        _require(out.sizes.get("latitude") == EXPECTED_LATITUDE_COUNT, f"{label}: latitude count is not 569")
        _require(out.sizes.get("longitude") == EXPECTED_LONGITUDE_COUNT, f"{label}: longitude count is not 1265")
        _validate_daily_time(out.valid_time.values, year, label)

        lat10 = _grid_in_tenths(out.latitude.values, f"{label} latitude")
        lon10 = _grid_in_tenths(out.longitude.values, f"{label} longitude")
        _require((lat10[0], lat10[-1]) == (713, 145), f"{label}: latitude range is not 71.3 to 14.5")
        _require((lon10[0], lon10[-1]) == (-1791, -527), f"{label}: longitude range is not -179.1 to -52.7")
        _require((lat10[563], lat10[564]) == (150, 149), f"{label}: seam is not 15.0/14.9")
        _require(np.array_equal(out.latitude.values[:564], usa.latitude.values), f"{label}: north latitude differs from USA")
        _require(np.array_equal(out.latitude.values[564:], south.latitude.values), f"{label}: south latitude differs from Mexico-south")
        _require(np.array_equal(out.longitude.values, usa.longitude.values), f"{label}: longitude differs from USA")

        encoding = out[variable].encoding
        _require(encoding.get("zlib") is True, f"{label}: zlib compression is disabled")
        _require(encoding.get("shuffle") is True, f"{label}: shuffle is disabled")
        _require(encoding.get("complevel") == 4, f"{label}: compression level is not 4")
        _require(tuple(encoding.get("chunksizes", ())) == OUTPUT_CHUNKS, f"{label}: chunks are not {OUTPUT_CHUNKS}")
        fill = encoding.get("_FillValue")
        _require(fill is not None and np.isnan(fill), f"{label}: fill value is not NaN")

        if full_values:
            north = out[variable].isel(latitude=slice(0, 564))
            south_out = out[variable].isel(latitude=slice(564, None))
            _require(_arrays_equal_with_nan(north, usa[variable]), f"{label}: north-side values differ from USA")
            _require(_arrays_equal_with_nan(south_out, south[variable]), f"{label}: south-side values differ from Mexico-south")

        return {
            "dimensions": f"valid_time={out.sizes['valid_time']};latitude={out.sizes['latitude']};longitude={out.sizes['longitude']}",
            "coordinate_bounds": (
                f"time={str(out.valid_time.values[0])[:10]}/{str(out.valid_time.values[-1])[:10]};"
                f"latitude={float(out.latitude.values[0]):.1f}/{float(out.latitude.values[-1]):.1f};"
                f"longitude={float(out.longitude.values[0]):.1f}/{float(out.longitude.values[-1]):.1f}"
            ),
            "units": str(out[variable].attrs["units"]),
        }
    finally:
        out.close()


def run(args: argparse.Namespace) -> int:
    started = time.monotonic()
    usa_path = source_path(args.input_root, "usa", args.variable, args.year)
    south_path = source_path(args.input_root, "mexico_south", args.variable, args.year)
    final_path = output_path(args.output_root, args.output_region, args.variable, args.year)
    tmp_path = temporary_path(final_path)
    print(f"variable={args.variable} year={args.year}", flush=True)
    print(f"usa_source={usa_path}", flush=True)
    print(f"mexico_south_source={south_path}", flush=True)
    print(f"output={final_path}", flush=True)

    usa = open_and_validate_source(usa_path, "usa", args.variable, args.year)
    south = None
    try:
        south = open_and_validate_source(south_path, "mexico_south", args.variable, args.year)
        validate_source_pair(usa, south, args.variable, args.year)
        print("source_validation=PASS", flush=True)

        if args.check_only:
            if final_path.exists():
                details = validate_output(final_path, usa, south, args.variable, args.year, args.output_region)
                print(f"output_validation=PASS {details}", flush=True)
            else:
                print("output_status=absent; source pair is ready", flush=True)
            return 0

        if final_path.exists() and not args.overwrite:
            details = validate_output(final_path, usa, south, args.variable, args.year, args.output_region)
            print(f"output_status=valid_existing_skip details={details}", flush=True)
            return 0

        final_path.parent.mkdir(parents=True, exist_ok=True)
        if tmp_path.exists():
            tmp_path.unlink()
        combined = build_combined(usa, south, args.variable, args.year, args.output_region, usa_path, south_path)
        try:
            print(f"writing_temporary={tmp_path}", flush=True)
            combined.to_netcdf(
                tmp_path,
                engine="netcdf4",
                format="NETCDF4",
                encoding=output_encoding(args.variable),
                compute=True,
            )
        finally:
            combined.close()

        details = validate_output(tmp_path, usa, south, args.variable, args.year, args.output_region)
        print(f"temporary_output_validation=PASS details={details}", flush=True)
        if final_path.exists() and not args.overwrite:
            _fail(f"Final output appeared during processing; refusing to overwrite: {final_path}")
        os.replace(tmp_path, final_path)
        print(f"finalized={final_path}", flush=True)
        print(f"output_size_bytes={final_path.stat().st_size}", flush=True)
        print(f"runtime_seconds={time.monotonic() - started:.3f}", flush=True)
        print(f"peak_rss_kb={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}", flush=True)
        return 0
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink()
        raise
    finally:
        usa.close()
        if south is not None:
            south.close()


def main() -> None:
    args = parse_args()
    try:
        raise SystemExit(run(args))
    except FileNotFoundError as exc:
        print(f"NOT_READY: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(3)
    except ValidationError as exc:
        print(f"VALIDATION_FAILED: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
