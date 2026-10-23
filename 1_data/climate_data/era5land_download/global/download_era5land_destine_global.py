#!/usr/bin/env python3
"""
download_era5land_destine_global.py

Purpose
-------
Download global ERA5-Land hourly data from the DestinE Earth Data Hub and reduce
it to daily variables, written one file per variable per month. Replaces
../download/download_era5land_destine_month_region.py, which pulled one bounding
box at a time and so lost upstream flow at the seams between boxes.

Reads in the store's own 60-day chunks rather than a month at a time. A month is
745 h but the store's time chunk is 1440 h, and a chunk cannot be partly read, so
month-sized requests fetch each chunk up to three times over: measured at 18
chunk fetches per year of 2020 against 7 for chunk-aligned reads, a 2.6x quota
saving. Because chunk edges never coincide with month edges, monthly output files
are assembled in a rolling buffer and written only once every day in them is in
hand. See the block-alignment section of the README.

The aggregation is copied from the region-month script unchanged, so this product
stays comparable with the existing regional archive.

Inputs
------
* DestinE ERA5-Land hourly Zarr store (ZARR_URL).
* Optional --start-year / --end-year. Default is everything the store holds.
* EDH_TOKEN in the environment. Run `source ~/.env_destine` first.

Outputs
-------
One compressed NetCDF per variable per month, in the layout
hydro/coarse/transform.py globs:

    <output-root>/global/<variable>/era5land_global_<variable>_<year>_<MM>.nc4

Files hold daily values grouped into monthly files; they are not monthly
aggregates. Longitude is rolled from the store's native 0..359.9 to -180..180 to
match the existing archive and the D8 DEM prepflow.py routes through; latitude is
left descending as the store provides it. Hourly data are never saved.

Rerun notes
-----------
A month counts as done when every variable file for it exists. A rerun computes
the months still missing, reads only the chunks those months need, and costs no
quota for work already finished. Writes go to a .tmp and are renamed only after
validation. Hitting the DestinE rate limit exits 4 and leaves finished months in
place.

Dependencies
------------
numpy, xarray, dask, zarr, fsspec, aiohttp, netCDF4, pandas
"""

import argparse
import calendar
import os
import random
import sys
import time
from pathlib import Path
from urllib.parse import quote

import dask
import numpy as np
import xarray as xr

# =============================================================================
# Constants
# =============================================================================

# Earth Data Hub documents this Zarr v3 store as the only version still
# receiving updates, and as more finely chunked than the v2 store the
# region-month scripts read. Note it is packed at a different binary precision
# than the v2 store, so values differ from the existing regional archive by one
# quantization step -- see the README comparison section.
ZARR_URL = "https://data.earthdatahub.destine.eu/era5/era5-land-v0.zarr"

# A new root, deliberately a sibling of the inherited ERA5-LAND tree rather than
# inside it. Point hydro/coarse/transform.py's `indir` here to read this product.
DEFAULT_OUTPUT_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily")

# Never write into the inherited archive.
PROTECTED_ROOTS = (
    Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily"),
    Path("/project/cil/battuta_shares/gcp/climate/ERA5-LAND/processed/daily"),
)

REGION = "global"
TIME = "valid_time"

# d2m and sp were dropped along with rh_mean and q_mean: nothing downstream reads
# them, and they were 2 of 7 fields on every fetch.
RAW_VARIABLES = ["t2m", "tp", "sd", "u10", "v10"]

DAILY_VARIABLES = ["tmin", "tmean", "tmax", "swe_mean", "tp_total", "wind_max"]

# Every daily variable except tp_total is a plain within-day reduction. tp_total
# needs one hour past the end of its day, which is what forces the carry in
# process_block().
TP = "tp_total"

# Retry on these; anything else is a bug and should fail immediately rather than
# burn 15 minutes of backoff. Matched against the text of whatever the
# zarr/aiohttp stack raises, which surfaces no stable exception type for 429.
RETRY_MARKERS = (
    "429", "too many requests", "quota", "rate limit",
    "500", "502", "503", "504", "timeout", "timed out",
    "connection reset", "server disconnected", "incomplete read",
    # A truncated chunk response: the store declares a content length, then
    # closes the connection early. Same transient failure as "incomplete read"
    # above, but aiohttp words it differently, so the marker list missed it and
    # job 59129655 died on block 1 instead of retrying. The embedded "400" in
    # aiohttp's message is its own ContentLengthError code, not an HTTP status,
    # so it is deliberately not added to the status markers above.
    "payload is not completed", "clientpayloaderror", "contentlengtherror",
)
QUOTA_MARKERS = ("429", "too many requests", "quota", "rate limit")

MAX_RETRIES = 5
RETRY_WAIT_SECONDS = 30.0
EXIT_QUOTA_EXHAUSTED = 4

HOURS_PER_DAY = 24


class QuotaExhausted(RuntimeError):
    pass


# =============================================================================
# Arguments and small helpers
# =============================================================================

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--start-year", type=int, default=None,
                   help="Default: the first year the store covers.")
    p.add_argument("--end-year", type=int, default=None,
                   help="Default: the last year the store covers. Set both to "
                        "the same year to price a single year before scaling up.")
    p.add_argument("--zarr-url", type=str, default=ZARR_URL)
    p.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    p.add_argument("--overwrite", action="store_true")
    return p.parse_args()


def variable_path(output_root: Path, variable: str, year: int, month: int) -> Path:
    # The layout hydro/coarse/transform.py globs.
    return (output_root / REGION / variable
            / f"era5land_{REGION}_{variable}_{year}_{month:02d}.nc4")


def month_is_complete(output_root: Path, year: int, month: int) -> bool:
    return all(variable_path(output_root, v, year, month).exists()
               for v in DAILY_VARIABLES)


def days_in_month(year: int, month: int) -> int:
    return calendar.monthrange(year, month)[1]


def assert_not_protected(root: Path) -> None:
    resolved = root.resolve()
    for protected in PROTECTED_ROOTS:
        if resolved == protected or protected in resolved.parents:
            raise SystemExit(
                f"Refusing to run: --output-root {resolved} is inside the "
                f"existing archive at {protected}. Pick a new root."
            )


def snap_to_tenths(values: np.ndarray) -> np.ndarray:
    """Put a coordinate on exact tenths of a degree.

    The store's coordinates carry float noise, since 0.1 is not representable in
    binary: the cell at 180 degrees comes back as 179.99999999999406. That noise
    is also what leaves values like 26.900000000001 in some existing regional
    files. Rounding through integer tenths removes it for good.
    """
    scaled = np.asarray(values, dtype=np.float64) * 10.0
    tenths = np.rint(scaled).astype(np.int64)
    assert np.all(np.abs(scaled - tenths) < 1e-3), "coordinate is not on a 0.1-deg grid"
    return tenths / 10.0


def signed_longitude(lon_native: np.ndarray):
    """Convert the store's 0..359.9 longitude to -180..180 ascending.

    Returns the new coordinate and the roll to apply to the data's last axis.
    Compared in integer tenths, not floats: the 180-degree cell arrives as
    179.99999999999406, so a `>= 180.0` test misses it and the roll lands one
    cell off. The -180.0 assert is what catches that; an ascending-order assert
    passes on the broken output.
    """
    tenths = np.rint(np.asarray(lon_native, dtype=np.float64) * 10.0).astype(np.int64)
    signed = np.where(tenths >= 1800, tenths - 3600, tenths) / 10.0

    roll = int(np.argmin(signed))
    longitude = np.roll(signed, -roll)

    assert np.all(np.diff(longitude) > 0), "rolled longitude is not ascending"
    assert longitude[0] == -180.0, \
        f"rolled longitude starts at {longitude[0]}, expected -180.0"
    return longitude, roll


def open_destine_dataset(url: str) -> xr.Dataset:
    # DestinE needs the token in the URL. Quote it so special characters do not
    # break the path.
    token = os.environ.get("EDH_TOKEN")
    if not token:
        raise SystemExit("EDH_TOKEN is not set. Run `source ~/.env_destine` first.")
    authed = url.replace("https://", f"https://edh:{quote(token, safe='')}@")

    # chunks={} adopts the store's chunking as dask chunks, so a block is
    # streamed at the store's own chunk size rather than materialised whole.
    return xr.open_dataset(authed, engine="zarr", chunks={})


def compute_with_retry(lazy, label: str):
    """Run one block's reduction, backing off exponentially on rate limits.

    Exponential rather than the linear retry in the CDS script, since HTTP 429
    is a standing rate limit and a linear retry walks straight back into it. The
    retry is per block because the fetch happens inside one dask compute; months
    already written stay written, so a quota stop costs at most the block in
    flight.
    """
    for attempt in range(1, MAX_RETRIES + 2):
        try:
            return lazy.compute()
        except Exception as exc:  # the zarr/aiohttp stack has no stable type
            text = f"{type(exc).__name__}: {exc}".lower()
            if not any(m in text for m in RETRY_MARKERS):
                raise
            if attempt > MAX_RETRIES:
                if any(m in text for m in QUOTA_MARKERS):
                    raise QuotaExhausted(f"{label}: {exc}") from exc
                raise
            wait = RETRY_WAIT_SECONDS * 2 ** (attempt - 1)
            wait += random.uniform(0, RETRY_WAIT_SECONDS)
            print(f"  RETRY {attempt}/{MAX_RETRIES} on {label}: sleeping "
                  f"{wait:.1f}s :: {exc}", flush=True)
            time.sleep(wait)


# =============================================================================
# Daily aggregation
# =============================================================================
#
# Unchanged from download_era5land_destine_month_region.py. The read geometry is
# what this script changes; the physics must not move, or the global product
# stops being comparable with the existing regional files.

def build_block_daily(hourly: xr.Dataset) -> xr.Dataset:
    """Reduce one block of hourly data to daily variables, lazily.

    Everything stays lazy until a single compute in the caller, so the hourly
    data are read once. The region-month script writes five files from five
    separate computes, which re-reads them five times over.

    The returned `tp_total` is deliberately one group longer at each end than
    the other variables; process_block() explains and resolves that.
    """
    # ERA5-Land temperature is Kelvin. Save daily temperature in Celsius.
    t2m_c = hourly["t2m"] - 273.15

    # Wind speed is not downloaded directly; compute it from the components.
    wind_speed = np.sqrt(hourly["u10"] ** 2 + hourly["v10"] ** 2)

    # ERA5-Land rain is accumulated, not an hourly rate. The midnight value
    # belongs to the day that just ended, so shift time back one hour and take
    # the daily maximum. Do not sum it.
    tp_shifted = hourly["tp"].assign_coords(
        valid_time=hourly[TIME] - np.timedelta64(1, "h")
    )

    return xr.Dataset({
        "tmin": t2m_c.resample(valid_time="1D").min(),
        "tmean": t2m_c.resample(valid_time="1D").mean(),
        "tmax": t2m_c.resample(valid_time="1D").max(),
        # Snow water equivalent is in meters. Save it in millimeters.
        "swe_mean": hourly["sd"].resample(valid_time="1D").mean() * 1000.0,
        "wind_max": wind_speed.resample(valid_time="1D").max(),
        TP: tp_shifted.resample(valid_time="1D").max() * 1000.0,
    })


# =============================================================================
# Rolling monthly buffer
# =============================================================================
#
# Store chunks are 60 days and never line up with month edges, so a block
# contributes days to two or three different months and no month is finished by
# any single block. Days are accumulated here and a month's files are written the
# moment its last day arrives, which keeps at most three months resident.

def buffer_add(buffer: dict, wanted: set, variable: str, days, values) -> None:
    """File a block's day-slices into their months. Unwanted months are dropped."""
    for day, plane in zip(days, values):
        day = np.datetime64(day, "D")
        year = day.astype("datetime64[Y]").astype(int) + 1970
        month = day.astype("datetime64[M]").astype(int) % 12 + 1
        if (year, month) not in wanted:
            continue

        slot = buffer.get((year, month))
        if slot is None:
            n_days = days_in_month(year, month)
            shape = (n_days,) + plane.shape
            slot = {
                "data": {v: np.empty(shape, dtype=np.float32)
                         for v in DAILY_VARIABLES},
                "filled": {v: np.zeros(n_days, dtype=bool)
                           for v in DAILY_VARIABLES},
            }
            buffer[(year, month)] = slot

        index = int((day - np.datetime64(f"{year}-{month:02d}-01")) /
                    np.timedelta64(1, "D"))
        slot["data"][variable][index] = plane
        slot["filled"][variable][index] = True


def buffer_flush(buffer: dict, output_root: Path, latitude, longitude,
                 zarr_url: str) -> list:
    """Write and drop every month whose every variable-day is present."""
    written = []
    for key in sorted(k for k, slot in buffer.items()
                      if all(f.all() for f in slot["filled"].values())):
        year, month = key
        slot = buffer.pop(key)
        for variable in DAILY_VARIABLES:
            write_variable(slot["data"][variable], variable, year, month,
                           output_root, latitude, longitude, zarr_url)
        written.append(key)
        print(f"  wrote {year}-{month:02d} "
              f"({len(DAILY_VARIABLES)} variables)", flush=True)
    return written


# =============================================================================
# Output
# =============================================================================

VARIABLE_ATTRS = {
    "tmin": {"long_name": "Daily minimum 2m air temperature", "units": "degC"},
    "tmean": {"long_name": "Daily mean 2m air temperature", "units": "degC"},
    "tmax": {"long_name": "Daily maximum 2m air temperature", "units": "degC"},
    "swe_mean": {
        "long_name": "Daily mean snow water equivalent", "units": "mm",
        "note": "Daily mean of hourly snow depth water equivalent, converted m to mm.",
    },
    TP: {
        "long_name": "Daily total precipitation", "units": "mm",
        "note": ("Computed from ERA5-Land accumulated hourly precipitation. "
                 "Timestamps shifted back 1 hour, daily maximum accumulation "
                 "used, converted m to mm."),
    },
    "wind_max": {
        "long_name": "Daily maximum 10m wind speed", "units": "m/s",
        "note": "Computed hourly as sqrt(u10^2 + v10^2), then daily maximum.",
    },
}


def write_variable(values, variable: str, year: int, month: int,
                   output_root: Path, latitude, longitude, zarr_url: str) -> None:
    """Write one variable's monthly file via a .tmp, validated before rename."""
    n_days = days_in_month(year, month)
    assert values.shape[0] == n_days, (values.shape, n_days)

    first = np.datetime64(f"{year}-{month:02d}-01")
    times = (first + np.arange(n_days, dtype="timedelta64[D]")).astype("datetime64[ns]")

    out = xr.Dataset(
        {variable: ((TIME, "latitude", "longitude"), values)},
        coords={TIME: times, "latitude": latitude, "longitude": longitude},
    )
    out[variable].attrs.update(VARIABLE_ATTRS[variable])
    out.attrs.update({
        "title": f"ERA5-Land daily {variable}, {REGION}, {year}-{month:02d}",
        "source": "ERA5-Land hourly data from DestinE Earth Data Hub Zarr",
        "source_store": zarr_url,
        "file_structure": ("Monthly single-variable file of daily values. "
                           "Concatenates along valid_time under "
                           "open_mfdataset(combine='by_coords')."),
    })

    encoding = {variable: {
        "dtype": "float32",
        "_FillValue": np.float32(np.nan),
        "zlib": True,
        "complevel": 4,
        # Matched to the dask chunks hydro/coarse/transform.py asks for
        # ({"latitude": 200, "longitude": 200}), so the consumer reads whole
        # chunks rather than slices of them. Clamped because netCDF4 rejects a
        # chunk larger than the dimension.
        "chunksizes": (n_days, min(200, len(latitude)), min(200, len(longitude))),
    }}

    path = variable_path(output_root, variable, year, month)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(".tmp.nc4")
    out.to_netcdf(tmp_path, engine="netcdf4", format="NETCDF4", encoding=encoding)

    # Check enough that the file's existence can mean "finished". Mirrors the
    # assertions normalize_raw() in transform.py makes, so a problem surfaces
    # here rather than downstream.
    with xr.open_dataset(tmp_path) as check:
        assert list(check.data_vars) == [variable], list(check.data_vars)
        assert check[variable].dims == (TIME, "latitude", "longitude"), \
            check[variable].dims
        assert check.sizes[TIME] == n_days, check.sizes[TIME]
        assert check.sizes["latitude"] == len(latitude)
        assert check.sizes["longitude"] == len(longitude)

    os.replace(tmp_path, path)


# =============================================================================
# Block processing
# =============================================================================

def process_block(ds, block: int, chunk_hours: int, n_time: int, buffer: dict,
                  wanted: set, carry: dict, lon_roll: int) -> tuple:
    """Fetch one store-aligned block, file its days, return (new carry, hours).

    The tp carry
    ------------
    A day's precipitation total needs the accumulation at 00:00 of the *next*
    day, so the last day of a block needs one hour that lives in the next block.
    Fetching it would pull a second chunk and give back the whole saving, so
    instead the block's partial maximum over that day's 23 available hours is
    carried forward and closed with the next block's first hour -- an hour that
    block is fetching anyway. The carry is one lat x lon array, about 20 MB.

    Concretely, resampling the back-shifted precipitation over a full block gives
    61 daily groups rather than 60:
      group 0     one hour, which closes the *previous* block's last day
      groups 1..59  59 complete days
      group 60    23 hours, carried to be closed by the next block
    """
    lo = block * chunk_hours
    hi = min((block + 1) * chunk_hours, n_time) - 1
    n_hours = hi - lo + 1

    # Blocks start at 00:00 because the store's chunk length is a whole number of
    # days, so a block is a whole number of days and no day is ever split.
    n_days_full = n_hours // HOURS_PER_DAY
    n_days_tp = (n_hours - 1) // HOURS_PER_DAY

    hourly = ds[RAW_VARIABLES].isel({TIME: slice(lo, hi + 1)})
    lazy = build_block_daily(hourly)

    t0 = time.time()
    daily = compute_with_retry(lazy, f"block {block}")
    fetch_min = (time.time() - t0) / 60

    # Roll the data onto the -180..180 longitude. The coordinate itself is
    # replaced at write time, so roll_coords is irrelevant here.
    daily = daily.roll(longitude=-lon_roll, roll_coords=False)

    # Building one Dataset from both the shifted and unshifted resamples unions
    # their time axes, so index 0 is the day *before* the block: real for
    # precipitation, NaN for everything else. Hence the [1:] below -- without it
    # every variable but precipitation is filed a day early and each block seam
    # lands a NaN day.
    days = daily[TIME].values
    assert len(days) == n_days_full + 1, (len(days), n_days_full)

    for variable in DAILY_VARIABLES:
        if variable == TP:
            continue
        buffer_add(buffer, wanted, variable, days[1:],
                   daily[variable].values[1:])

    tp = daily[TP].values

    # Group 0 closes the previous block's last day, if there is one to close.
    if carry is not None:
        closed = np.maximum(carry["partial"], tp[0])
        buffer_add(buffer, wanted, TP, [carry["day"]], closed[None, ...])
    elif block > 0:
        # Only legitimate at the very start of a run, where the preceding day
        # belongs to a month this run was not asked to produce.
        print(f"  note: no carry into block {block}; its first day's "
              f"precipitation is not emitted", flush=True)

    # Groups 1..n_days_tp are complete days of this block.
    buffer_add(buffer, wanted, TP, days[1:n_days_tp + 1], tp[1:n_days_tp + 1])

    # The final group is short by its closing hour. Carry it, unless the store
    # simply ends here and there is no next block to close it with.
    new_carry = None
    if n_days_tp + 1 < len(tp):
        new_carry = {"day": days[n_days_tp + 1], "partial": tp[n_days_tp + 1]}

    print(f"  block {block}: {n_hours} h, {n_days_full} days, "
          f"fetch+reduce {fetch_min:.2f} min", flush=True)
    return new_carry, n_hours


# =============================================================================
# Main
# =============================================================================

def main():
    args = parse_args()
    assert_not_protected(args.output_root)

    # Match hydro/coarse/transform.py: use the cores Slurm actually gave us.
    nthreads = int(os.environ.get("SLURM_CPUS_PER_TASK", 1))
    dask.config.set(scheduler="threads", num_workers=nthreads)

    print("===== ERA5-LAND DESTINE GLOBAL =====", flush=True)
    print(f"Store:        {args.zarr_url}", flush=True)
    print(f"Output root:  {args.output_root / REGION}", flush=True)
    print(f"Dask threads: {nthreads}", flush=True)
    print(f"Raw fields:   {RAW_VARIABLES}", flush=True)
    print(f"Daily vars:   {DAILY_VARIABLES}", flush=True)

    t_start = time.time()
    print("Opening DestinE Zarr dataset...", flush=True)
    ds = open_destine_dataset(args.zarr_url)
    print(f"Open time: {(time.time() - t_start) / 60:.2f} min", flush=True)

    try:
        assert ds[RAW_VARIABLES[0]].dims[0] == TIME, ds[RAW_VARIABLES[0]].dims
        store_chunks = ds[RAW_VARIABLES[0]].encoding.get("chunks")
        assert store_chunks, "store reports no chunk shape; cannot align reads"
        chunk_hours, chunk_lat, chunk_lon = store_chunks
        assert chunk_hours % HOURS_PER_DAY == 0, \
            f"time chunk {chunk_hours} h is not a whole number of days"

        index = ds.indexes[TIME]
        n_time = len(index)
        assert index[0] == index[0].normalize(), \
            f"store does not start at 00:00 ({index[0]}); blocks would split days"

        latitude = snap_to_tenths(ds["latitude"].values)
        longitude, lon_roll = signed_longitude(ds["longitude"].values)

        space_blocks = (-(-len(latitude) // chunk_lat)) * \
                       (-(-len(longitude) // chunk_lon))
        chunk_gb = chunk_hours * chunk_lat * chunk_lon * 4 / 1024 ** 3

        print(f"Store time:   {index[0]} .. {index[-1]} ({n_time:,} h)", flush=True)
        print(f"Store chunk:  {store_chunks}  "
              f"({chunk_hours // HOURS_PER_DAY}-day blocks, "
              f"{space_blocks} spatial blocks, {chunk_gb:.3f} GB each)", flush=True)
        print(f"Latitude:     {latitude[0]} .. {latitude[-1]} "
              f"({len(latitude)} rows)", flush=True)
        print(f"Longitude:    {longitude[0]} .. {longitude[-1]} "
              f"(rolled by {lon_roll})", flush=True)

        # A day's precipitation needs the next day's 00:00, so the store's final
        # day can never be completed and its month is not offered.
        last_day = (index[-1] - np.timedelta64(1, "h")).normalize() - \
            np.timedelta64(1, "D")
        first_day = index[0].normalize()
        start_year = args.start_year or first_day.year
        end_year = args.end_year or last_day.year

        wanted = set()
        skipped = 0
        for year in range(start_year, end_year + 1):
            for month in range(1, 13):
                last = np.datetime64(f"{year}-{month:02d}-"
                                     f"{days_in_month(year, month):02d}")
                if (np.datetime64(f"{year}-{month:02d}-01") <
                        np.datetime64(first_day.date())):
                    continue
                if last > np.datetime64(last_day.date()):
                    continue
                if not args.overwrite and month_is_complete(args.output_root,
                                                            year, month):
                    skipped += 1
                    continue
                wanted.add((year, month))

        print(f"Years:        {start_year}..{end_year}", flush=True)
        print(f"Months done:  {skipped}", flush=True)
        print(f"Months to do: {len(wanted)}", flush=True)

        if not wanted:
            print("Nothing to do; every month in range already exists.", flush=True)
            return

        # Exactly the blocks holding the hours the wanted days need, and no more.
        #
        # No leading block. A day's precipitation window is hours [D*24+1,
        # (D+1)*24], which starts *after* its own 00:00, so the first wanted day
        # is always served by its own block and nothing earlier is required. The
        # "no carry" note below fires on that block and is harmless: its group 0
        # is the day before, which belongs to a month this run was not asked for.
        # An earlier version fetched one block before this, which on a 2025 run
        # meant fetching 2024-09-29..2024-11-27 and discarding all of it.
        #
        # For the tail, the last wanted day closes on hour (D+1)*24. That hour is
        # in the same block unless the day sits last in its block; taking the
        # block of the closing hour resolves both cases. An earlier version added
        # a whole block unconditionally, which on a 2025 run fetched
        # 2026-01-22..2026-03-22 for nothing. Together the two cost 2 of 9
        # blocks, 22% of a single-year run.
        def block_of_hour(when) -> int:
            return int((np.datetime64(when, "h") - np.datetime64(index[0], "h"))
                       / np.timedelta64(1, "h")) // chunk_hours

        first_block = min(block_of_hour(f"{y}-{m:02d}-01") for y, m in wanted)
        last_block = max(
            block_of_hour(np.datetime64(f"{y}-{m:02d}-{days_in_month(y, m):02d}")
                          + np.timedelta64(1, "D"))
            for y, m in wanted
        )
        last_block = min(last_block, -(-n_time // chunk_hours) - 1)
        blocks = range(first_block, last_block + 1)

        wanted_hours = sum(
            days_in_month(y, m) * HOURS_PER_DAY for y, m in wanted) + 1
        print(f"Blocks:       {first_block}..{last_block} ({len(blocks)} blocks, "
              f"{len(blocks) * space_blocks * len(RAW_VARIABLES):,} chunk reads, "
              f"{len(blocks) * space_blocks * len(RAW_VARIABLES) * chunk_gb / 1024:.2f} TB)",
              flush=True)
        # Near 1.0 on a full run. High on a small rerun, where a handful of
        # months still cost whole blocks -- expected, not a problem.
        print(f"Over-read:    "
              f"{len(blocks) * chunk_hours / wanted_hours:.2f}x in time "
              f"(month-at-a-time reads about 2.95x on a full year)", flush=True)

        buffer = {}
        carry = None
        months_written = []
        hours_read = 0

        for block in blocks:
            carry, n_hours = process_block(
                ds, block, chunk_hours, n_time, buffer, wanted, carry, lon_roll,
            )
            hours_read += n_hours
            months_written += buffer_flush(buffer, args.output_root, latitude,
                                           longitude, args.zarr_url)
    finally:
        ds.close()

    total_minutes = (time.time() - t_start) / 60
    n_blocks = len(blocks)
    chunk_reads = n_blocks * space_blocks * len(RAW_VARIABLES)

    print("\n===== SUMMARY =====", flush=True)
    print(f"Blocks fetched:    {n_blocks}", flush=True)
    print(f"Chunk reads:       {chunk_reads:,}", flush=True)
    print(f"Quota (decomp):    {chunk_reads * chunk_gb / 1024:.3f} TB", flush=True)
    print(f"Hours read:        {hours_read:,} for {wanted_hours:,} wanted", flush=True)
    print(f"Months written:    {len(months_written)}", flush=True)
    print(f"Months incomplete: {len(buffer)} "
          f"{sorted(buffer) if buffer else ''}", flush=True)
    print(f"Total runtime:     {total_minutes:.2f} min", flush=True)

    if n_blocks:
        per_block = total_minutes / n_blocks
        all_blocks = -(-n_time // chunk_hours)
        print(f"Per block:         {per_block:.2f} min", flush=True)
        print(f"--- projection to the whole store ({all_blocks} blocks) ---",
              flush=True)
        print(f"  time:            {per_block * all_blocks / 60:.1f} h", flush=True)
        print(f"  quota (decomp):  "
              f"{all_blocks * space_blocks * len(RAW_VARIABLES) * chunk_gb / 1024:.2f} TB",
              flush=True)


if __name__ == "__main__":
    try:
        main()
    except QuotaExhausted as exc:
        # A distinct exit code so hitting the DestinE quota gives one clear
        # diagnosis. Months already written stay written, and a rerun picks up
        # from the first missing month.
        print(f"QUOTA_EXHAUSTED: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(EXIT_QUOTA_EXHAUSTED)
