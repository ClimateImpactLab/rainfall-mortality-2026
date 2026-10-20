#!/usr/bin/env python3
"""Combine one India/East Asia ERA5-Land variable-year along longitude.

Why this exists
---------------
The original India download included India plus relevant HydroBASINS areas, but
it was capped at 120E. Other Asian countries were needed later, so `asia_east`
was downloaded as a separate box starting at 120.1E. This script joins the two
annual daily files into the final `asia_combined` folder.

Inputs
------
Annual single-variable files in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/{india,asia_east}/<variable>/

Output
------
One annual single-variable file in:

    /project/cil/gcp/climate/ERA5-LAND/raw/daily/asia_combined/<variable>/

Rerun notes
-----------
Safe to rerun if the output is absent. Existing outputs are validated and
skipped unless `--overwrite` is used. This script scans and writes NetCDF files,
so run batches on a compute node.

Important assumption
--------------------
The two sources must touch exactly on the 0.1-degree grid. No interpolation,
averaging, or regridding is done.
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
YEAR_MIN = 1975
YEAR_MAX = 2024
DEFAULT_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily")
EXPECTED_DIMS = ("valid_time", "latitude", "longitude")
EXPECTED_LATITUDE_COUNT = 548
EXPECTED_INDIA_LONGITUDE_COUNT = 624
EXPECTED_EAST_LONGITUDE_COUNT = 300
EXPECTED_LONGITUDE_COUNT = 924
OUTPUT_CHUNKS = (31, 137, 231)
GRID_DECIMALS = 1
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
    parser.add_argument("--output-region", default="asia_combined")
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
    """Represent decimal-degree grid coordinates as exact integer tenths.

    NetCDF coordinates are binary float64, so literal subtraction cannot equal
    decimal 0.1. This conversion first verifies that every value is within
    1e-8 degrees of a tenth, then validates spacing exactly in integer units.
    """
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
        _fail(f"{label}: valid_time is not a decoded proleptic-Gregorian datetime coordinate: {exc}")
    _require(np.array_equal(actual_days, expected), f"{label}: valid_time is not the complete daily sequence for {year}")
    _require(
        np.array_equal(actual_ns, expected.astype("datetime64[ns]")),
        f"{label}: valid_time values are not daily timestamps at 00:00:00",
    )


def _validate_coordinate_geometry(ds: xr.Dataset, region: str, label: str) -> None:
    _require(ds.sizes.get("latitude") == EXPECTED_LATITUDE_COUNT, f"{label}: expected 548 latitude rows")
    lat10 = _grid_in_tenths(ds.latitude.values, f"{label} latitude")
    _require(lat10[0] == 559 and lat10[-1] == 12, f"{label}: latitude bounds are not 55.9 to 1.2")
    _require(np.array_equal(np.diff(lat10), -np.ones(len(lat10) - 1, dtype=np.int64)), f"{label}: latitude is not descending by exactly 0.1 degrees")

    lon10 = _grid_in_tenths(ds.longitude.values, f"{label} longitude")
    expected_count = EXPECTED_INDIA_LONGITUDE_COUNT if region == "india" else EXPECTED_EAST_LONGITUDE_COUNT
    expected_bounds = (577, 1200) if region == "india" else (1201, 1500)
    _require(ds.sizes.get("longitude") == expected_count, f"{label}: expected {expected_count} longitude columns")
    _require((lon10[0], lon10[-1]) == expected_bounds, f"{label}: unexpected longitude bounds")
    _require(np.array_equal(np.diff(lon10), np.ones(len(lon10) - 1, dtype=np.int64)), f"{label}: longitude is not strictly increasing by exactly 0.1 degrees")


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


def validate_source_pair(india: xr.Dataset, east: xr.Dataset, variable: str, year: int) -> None:
    # These checks make sure the merge is just concatenation. If any of them
    # fails, it is safer to stop than to silently resample a climate grid.
    _require(np.array_equal(india.latitude.values, east.latitude.values), "India and East Asia latitude coordinates are not exactly equal")
    _require(np.array_equal(india.valid_time.values, east.valid_time.values), "India and East Asia time coordinates are not exactly equal")
    _require(india[variable].attrs.get("units") == east[variable].attrs.get("units"), "India and East Asia units do not agree")
    _require(india[variable].dtype == east[variable].dtype, "India and East Asia dtypes do not agree")
    india10 = _grid_in_tenths(india.longitude.values, "India longitude")
    east10 = _grid_in_tenths(east.longitude.values, "East Asia longitude")
    _require(east10[0] - india10[-1] == 1, "East Asia does not begin exactly one 0.1-degree grid step after India")
    combined10 = np.concatenate([india10, east10])
    _require(len(np.unique(combined10)) == len(combined10), "Combined longitude has duplicates")
    _require(np.array_equal(np.diff(combined10), np.ones(len(combined10) - 1, dtype=np.int64)), "Combined longitude spacing is not uniformly 0.1 degrees")
    _require(len(combined10) == EXPECTED_LONGITUDE_COUNT, "Combined longitude count is not 924")
    _validate_daily_time(india.valid_time.values, year, "source pair")


def _clean_source(ds: xr.Dataset, variable: str) -> xr.Dataset:
    data = ds[variable].reset_coords(drop=True)
    return xr.Dataset(
        data_vars={variable: (EXPECTED_DIMS, data.data, dict(data.attrs))},
        coords={
            name: (name, ds[name].values, dict(ds[name].attrs))
            for name in EXPECTED_DIMS
        },
    )


# =============================================================================
# 4. Dataset Construction
# =============================================================================

def build_combined(
    india: xr.Dataset,
    east: xr.Dataset,
    variable: str,
    year: int,
    output_region: str,
    india_path: Path,
    east_path: Path,
) -> xr.Dataset:
    combined = xr.concat(
        [_clean_source(india, variable), _clean_source(east, variable)],
        dim="longitude",
        data_vars="minimal",
        coords="minimal",
        compat="equals",
        join="exact",
    ).chunk(dict(zip(EXPECTED_DIMS, OUTPUT_CHUNKS)))

    attrs = dict(india[variable].attrs)
    attrs["units"] = india[variable].attrs["units"]
    for key, value in {
        "GRIB_Nx": EXPECTED_LONGITUDE_COUNT,
        "GRIB_numberOfPoints": EXPECTED_LATITUDE_COUNT * EXPECTED_LONGITUDE_COUNT,
        "GRIB_longitudeOfFirstGridPointInDegrees": 57.7,
        "GRIB_longitudeOfLastGridPointInDegrees": 150.0,
    }.items():
        if key in attrs:
            attrs[key] = value
    combined[variable].attrs = attrs
    combined.attrs = {
        "title": f"ERA5-Land daily {variable} for {output_region}, {year}",
        "region": output_region,
        "year": str(year),
        "variable": variable,
        "source_regions": "india; asia_east",
        "india_data_source": str(india.attrs.get("source", "")),
        "asia_east_data_source": str(east.attrs.get("source", "")),
        "india_source_file": str(india_path),
        "asia_east_source_file": str(east_path),
        "source_files": f"{india_path}; {east_path}",
        "latitude_bounds": "55.9; 1.2 (descending)",
        "longitude_bounds": "57.7; 150.0 (increasing)",
        "creation_timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "combination_method": "The India and East Asia domains were directly concatenated by longitude.",
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
    india: xr.Dataset,
    east: xr.Dataset,
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
        _require(
            set(out.coords) == set(EXPECTED_DIMS),
            f"{label}: unexpected coordinates {sorted(set(out.coords) - set(EXPECTED_DIMS))}",
        )
        _require(out[variable].dims == EXPECTED_DIMS, f"{label}: incorrect dimensions {out[variable].dims}")
        _require(out.attrs.get("region") == output_region, f"{label}: incorrect region metadata")
        _require(str(out.attrs.get("year")) == str(year), f"{label}: incorrect year metadata")
        _require(out.attrs.get("variable") == variable, f"{label}: incorrect variable metadata")
        _require(out.attrs.get("source_regions") == "india; asia_east", f"{label}: incorrect source_regions metadata")
        _require(np.dtype(out[variable].dtype) == np.dtype("float32"), f"{label}: storage dtype is not float32")
        _require(out[variable].attrs.get("units") == india[variable].attrs.get("units"), f"{label}: units differ from sources")
        _require(out.sizes.get("valid_time") == expected_days(year), f"{label}: incorrect number of days")
        _require(out.sizes.get("latitude") == EXPECTED_LATITUDE_COUNT, f"{label}: latitude count is not 548")
        _require(out.sizes.get("longitude") == EXPECTED_LONGITUDE_COUNT, f"{label}: longitude count is not 924")
        _validate_daily_time(out.valid_time.values, year, label)
        _require(np.array_equal(out.latitude.values, india.latitude.values), f"{label}: latitude differs from India")
        _require(np.array_equal(out.latitude.values, east.latitude.values), f"{label}: latitude differs from East Asia")
        _require(np.array_equal(out.valid_time.values, india.valid_time.values), f"{label}: time differs from India")
        _require(np.array_equal(out.valid_time.values, east.valid_time.values), f"{label}: time differs from East Asia")
        lon10 = _grid_in_tenths(out.longitude.values, f"{label} longitude")
        _require((lon10[0], lon10[-1]) == (577, 1500), f"{label}: longitude range is not 57.7 to 150.0")
        _require(np.array_equal(np.diff(lon10), np.ones(EXPECTED_LONGITUDE_COUNT - 1, dtype=np.int64)), f"{label}: longitude spacing is not exactly 0.1 degrees")
        _require((lon10[623], lon10[624]) == (1200, 1201), f"{label}: seam is not 120.0/120.1")
        _require(np.array_equal(out.longitude.values[:624], india.longitude.values), f"{label}: west longitude coordinate differs from India")
        _require(np.array_equal(out.longitude.values[624:], east.longitude.values), f"{label}: east longitude coordinate differs from East Asia")

        encoding = out[variable].encoding
        _require(encoding.get("zlib") is True, f"{label}: zlib compression is disabled")
        _require(encoding.get("shuffle") is True, f"{label}: shuffle is disabled")
        _require(encoding.get("complevel") == 4, f"{label}: compression level is not 4")
        _require(tuple(encoding.get("chunksizes", ())) == OUTPUT_CHUNKS, f"{label}: chunks are not {OUTPUT_CHUNKS}")
        fill = encoding.get("_FillValue")
        _require(fill is not None and np.isnan(fill), f"{label}: fill value is not NaN")

        west = out[variable].isel(longitude=slice(0, 624))
        east_out = out[variable].isel(longitude=slice(624, None))
        if full_values:
            _require(_arrays_equal_with_nan(west, india[variable]), f"{label}: west-side values or missing masks differ from India")
            _require(_arrays_equal_with_nan(east_out, east[variable]), f"{label}: east-side values or missing masks differ from East Asia")

        return {
            "dimensions": "valid_time={};latitude={};longitude={}".format(
                out.sizes["valid_time"], out.sizes["latitude"], out.sizes["longitude"]
            ),
            "coordinate_bounds": "time={}/{};latitude={:.1f}/{:.1f};longitude={:.1f}/{:.1f}".format(
                str(out.valid_time.values[0])[:10],
                str(out.valid_time.values[-1])[:10],
                float(out.latitude.values[0]),
                float(out.latitude.values[-1]),
                float(out.longitude.values[0]),
                float(out.longitude.values[-1]),
            ),
            "units": str(out[variable].attrs["units"]),
        }
    finally:
        out.close()


def run(args: argparse.Namespace) -> int:
    started = time.monotonic()
    india_path = source_path(args.input_root, "india", args.variable, args.year)
    east_path = source_path(args.input_root, "asia_east", args.variable, args.year)
    final_path = output_path(args.output_root, args.output_region, args.variable, args.year)
    tmp_path = temporary_path(final_path)
    print(f"variable={args.variable} year={args.year}", flush=True)
    print(f"india_source={india_path}", flush=True)
    print(f"asia_east_source={east_path}", flush=True)
    print(f"output={final_path}", flush=True)

    india = open_and_validate_source(india_path, "india", args.variable, args.year)
    east = None
    try:
        east = open_and_validate_source(east_path, "asia_east", args.variable, args.year)
        validate_source_pair(india, east, args.variable, args.year)
        print("source_validation=PASS", flush=True)

        if args.check_only:
            if final_path.exists():
                details = validate_output(final_path, india, east, args.variable, args.year, args.output_region)
                print(f"output_validation=PASS {details}", flush=True)
            else:
                print("output_status=absent; source pair is ready", flush=True)
            return 0

        if final_path.exists() and not args.overwrite:
            details = validate_output(final_path, india, east, args.variable, args.year, args.output_region)
            print(f"output_status=valid_existing_skip details={details}", flush=True)
            return 0

        final_path.parent.mkdir(parents=True, exist_ok=True)
        if tmp_path.exists():
            tmp_path.unlink()
        combined = build_combined(
            india, east, args.variable, args.year, args.output_region, india_path, east_path
        )
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

        details = validate_output(tmp_path, india, east, args.variable, args.year, args.output_region)
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
        india.close()
        if east is not None:
            east.close()


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
