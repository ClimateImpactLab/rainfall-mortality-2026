#!/usr/bin/env python3
"""
03_global_cell_stats.py

Rainfall vs rainfall_flow statistics for every 0.5-degree box of land in one
latitude band of the global grid.

This is the global version of the county comparison in
01_rain_vs_flow_figures.R, built the same way. A box of 5 x 5 ERA5-Land cells
(0.1 degree each) plays the role of a county: its monthly rainfall and flow
are weighted means over its cells, as an admin unit's are in
era5land_admin and 01_aggregate_monthly_flow.py. There are two versions:
  _pop   LandScan 2011 population weights (what the US comparison used)
  _area  GPW 2010 land-area weights (the admin files' *_area columns)

Rainfall = tp_total, the precipitation behind the mortality regressions:
  daily ERA5-Land totals summed over each month (mm).
Flow = rainfall_flow, the flow used for the admin files (see flow_common.py):
  tp_total minus the daily change in snow water equivalent, summed over every
  upstream cell on the D8 river network, each month routed on its own (mm
  summed over upstream cells).

The drought and flood measures are a box's annual mean and annual max of its
monthly values, built the same way for flow and rainfall, as in the US
summary table.

One row per box with any land cell with complete data, 1950-2025:
  box_row, box_col     position of the box, counted from 90N and 180W
  lat, lon             centre of the box's cells
  n_cells              cells with complete data
  pop                  LandScan 2011 population in those cells
  land_area_km2        GPW 2010 land area in those cells
and, for each weighting (suffix _pop or _area):
  rain_mean            mean monthly rainfall (mm)
  flow_mean            mean monthly flow (mm summed over upstream cells)
  upstream_ratio       flow_mean / rain_mean
  corr_month           correlation of the monthly series, seasonal cycle included
  corr_drought         correlation of the annual means
  corr_flood           correlation of the annual maxima
  rain_peak_month      calendar month with the highest mean rainfall
  flow_peak_month      calendar month with the highest mean flow
  peak_shift           months from the rainfall peak to the flow peak, -5 to 6,
                       positive = flow peaks later
  snow_share           share of precipitation that goes into the snowpack
                       before it reaches the flow input
A weighting's columns are empty for a box whose weights sum to zero (no
people, or no GPW land area).

Inputs:
- daily global tp_total, one file per month (settings.monthly_climate_file)
- global monthly flow, one file per year (flow_common.flow_file), from
  hydro/coarse/prepflow.py
- monthly flow input (tp_total minus the SWE change), one file per latitude
  band, global_monthly_band{band}.nc4 next to the flow files, from
  hydro/coarse/transform.py; it gives snow_share and fixes the band's rows
- LandScan 2011 population (settings.LANDSCAN)
- GPW 2010 land-area points (settings.GPW_LAND_AREA)

Outputs (OUTPUT_ROOT/ERA5-LAND-GLOBAL/GLOBAL/hydro/rain_vs_flow_boxes/):
- box_stats_band{band}.csv      one row per box with land
- band_summary_band{band}.csv   cell, box, population and land-area counts

Dependencies: era5land_admin/settings.py and common.py, plus flow_common.py
(on PYTHONPATH through jobs/rain_vs_flow_global.sbatch).

Run through Slurm, one task per band, from climate_aggregation_global:
  sbatch --array=0-7 hydro_era5land_admin/jobs/rain_vs_flow_global.sbatch
Then run 04_global_figures.R.
"""

# -----------------
# Packages
# -----------------

import argparse
import calendar
import sys

import numpy as np
import pandas as pd
import pyarrow.dataset as pads
from netCDF4 import Dataset

from common import CheckError, atomic_csv, read_grid, require
from settings import GPW_LAND_AREA, LANDSCAN, OUTPUT_ROOT, PRODUCT, monthly_climate_file
from flow_common import FLOW_ROOT, FLOW_VARIABLE, flow_file, month_starts


# -----------------------------
# Settings
# -----------------------------

# Same years as the USA comparison (first_year and last_year of the countries
# in settings.py)
YEARS = range(1950, 2026)

# Cells per box side: 5 x 5 cells of 0.1 degree = one 0.5-degree box, about
# 55 x 43 km at 40N, which is roughly county-sized. Boxes are counted from
# 90N and 180W, so the bands of 200 rows split into whole boxes; the last band
# (72 rows) ends in a box of 2 rows at 57S.
BOX = 5

OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "GLOBAL" / "hydro" / "rain_vs_flow_boxes"


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--band", type=int, required=True)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Read the band's rows of each input
# -----------------------------

def expected_months():
    return pd.date_range(f"{YEARS[0]}-01-01", periods=12 * len(YEARS), freq="MS")


def read_flow_input(band):
    """Latitudes and longitudes of one band, and its monthly flow input.

    The band files set which rows of the global grid a task covers. Their
    latitudes run south to north, like the flow files.
    """

    path = FLOW_ROOT / f"global_monthly_band{band}.nc4"
    require(path.is_file(), f"Missing band file: {path}")

    with Dataset(path) as data:
        # Plain arrays: NaN marks missing values, so no masked arrays
        data.set_auto_mask(False)
        latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
        longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
        require(np.all(np.diff(latitude) > 0), f"Latitudes do not run south to north: {path}")

        # The band file covers every month of the run; keep the months of YEARS
        months = month_starts(data)
        wanted = expected_months()
        require(wanted.isin(months).all(), f"{path} is missing months of {YEARS[0]}-{YEARS[-1]}")
        positions = np.flatnonzero(months.isin(wanted))
        require(months[positions].equals(wanted), f"Months out of order in {path}")

        variable = data.variables["rainfall"]
        require(
            variable.dimensions == ("valid_time", "latitude", "longitude"),
            f"Unexpected dimensions for rainfall in {path}: {variable.dimensions}",
        )
        values = np.asarray(variable[positions[0]:positions[-1] + 1], dtype="float32")

    return latitude, longitude, values


def read_flow(latitude, longitude):
    """Month x latitude x longitude flow for the band's rows."""

    flow = np.empty((12 * len(YEARS), len(latitude), len(longitude)), dtype="float32")

    for i, year in enumerate(YEARS):
        path = flow_file(year)
        require(path.is_file(), f"Missing flow input: {path}")

        with Dataset(path) as data:
            data.set_auto_mask(False)
            expected = pd.date_range(f"{year}-01-01", periods=12, freq="MS")
            require(month_starts(data).equals(expected), f"Monthly dates are incomplete for {year}: {path}")

            # The flow files run south to north, like the band files, so the
            # band is one block of rows
            file_latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
            file_longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
            require(np.allclose(file_longitude, longitude), f"Longitudes differ from the band file: {path}")
            first = int(np.argmin(np.abs(file_latitude - latitude[0])))
            rows = slice(first, first + len(latitude))
            require(np.allclose(file_latitude[rows], latitude), f"Band latitudes not found in {path}")

            variable = data.variables[FLOW_VARIABLE]
            require(
                variable.dimensions == ("valid_time", "latitude", "longitude"),
                f"Unexpected dimensions for {FLOW_VARIABLE} in {path}: {variable.dimensions}",
            )
            flow[12 * i:12 * i + 12] = variable[:, rows, :]

    return flow


def read_rainfall(latitude, longitude):
    """Month x latitude x longitude tp_total, summed from the daily files."""

    rain = np.empty((12 * len(YEARS), len(latitude), len(longitude)), dtype="float32")

    for i, year in enumerate(YEARS):
        for month in range(1, 13):
            path = monthly_climate_file("tp_total", year, month)
            require(path.is_file(), f"Missing tp_total input: {path}")

            with Dataset(path) as data:
                data.set_auto_mask(False)
                n_days = calendar.monthrange(year, month)[1]
                require(data.dimensions["valid_time"].size == n_days, f"{path} does not have {n_days} days")

                # The tp_total files run north to south, so the band's rows
                # are read as one block and flipped
                file_latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
                file_longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
                require(np.allclose(file_longitude, longitude), f"Longitudes differ from the band file: {path}")
                first = int(np.argmin(np.abs(file_latitude - latitude[-1])))
                rows = slice(first, first + len(latitude))
                require(np.allclose(file_latitude[rows][::-1], latitude), f"Band latitudes not found in {path}")

                variable = data.variables["tp_total"]
                require(getattr(variable, "units", None) == "mm", f"tp_total units are not mm: {path}")

                # A month with any missing day stays missing (NaN propagates)
                daily = np.asarray(variable[:, rows, :], dtype="float64")
                rain[12 * i + month - 1] = daily.sum(axis=0)[::-1]

    return rain


def read_population(latitude, longitude):
    """LandScan 2011 population in each ERA5-Land cell of the band.

    An ERA5-Land cell is centred on its 0.1-degree coordinates and spans
    0.05 degrees each way, which is exactly 12 x 12 LandScan cells (1/120
    degree). Summing those blocks assigns each LandScan pixel to the cell
    containing its centre, as 01_make_weights.py does. LandScan stops at 84N;
    cells beyond it get no population.
    """

    header = {}
    for line in LANDSCAN.with_suffix(".hdr").read_text().splitlines():
        if line.strip():
            key, value = line.split()
            header[key.lower()] = value

    n_rows, n_cols = int(header["nrows"]), int(header["ncols"])
    require(header["byteorder"] == "LSBFIRST", "LandScan is not little-endian")
    require(float(header["xllcorner"]) == -180, "LandScan does not start at 180W")
    per_degree = round(1 / float(header["cellsize"]))
    per_cell = per_degree // 10
    require(per_degree == 120 and n_cols == per_cell * len(longitude), "LandScan grid does not nest in the 0.1-degree grid")
    require(np.isclose(longitude[0], -180) and np.allclose(np.diff(longitude), 0.1), "Unexpected ERA5-Land longitudes")

    top = float(header["yllcorner"]) + n_rows / per_degree
    grid = np.memmap(LANDSCAN, dtype="<f4", mode="r", shape=(n_rows, n_cols))

    population = np.zeros((len(latitude), len(longitude)))
    for i, lat in enumerate(latitude):
        first = round((top - (lat + 0.05)) * per_degree)
        if first < 0 or first + per_cell > n_rows:
            continue

        values = np.asarray(grid[first:first + per_cell], dtype="float64")
        # NODATA (-9999) is water: no people
        values[values < 0] = 0
        # Each ERA5-Land cell starts half a cell (6 LandScan columns) west of
        # its longitude; rolling by 6 lines the blocks up, wrapping at 180
        values = np.roll(values, per_cell // 2, axis=1)
        population[i] = values.reshape(per_cell, len(longitude), per_cell).sum(axis=(0, 2))

    return population


def read_land_area(grid, grid_rows):
    """GPW 2010 land area (km2) in each ERA5-Land cell of the band.

    Each GPW point goes to the cell containing it through grid.point_indices,
    as in 01_make_weights.py. The points are not sorted by latitude, so every
    file is scanned and the band's points kept.
    """

    first, last = int(grid_rows.min()), int(grid_rows.max())
    n_lon = len(grid.longitude)
    area = np.zeros((last - first + 1) * n_lon)

    dataset = pads.dataset(GPW_LAND_AREA, format="parquet")
    latitude = pads.field("latitude")
    keep = (latitude <= grid.top - (first - 1) * grid.step) & (latitude >= grid.top - (last + 2) * grid.step)

    for batch in dataset.to_batches(columns=["longitude", "latitude", "land_area"], filter=keep, batch_size=500_000):
        points = batch.to_pandas()
        land = pd.to_numeric(points["land_area"], errors="raise").to_numpy()
        require((land > 0).all(), "GPW land area must be positive")

        rows, columns, inside = grid.point_indices(points["latitude"].to_numpy(), points["longitude"].to_numpy())
        inside &= (rows >= first) & (rows <= last)
        codes = (rows[inside] - first) * n_lon + columns[inside]
        area += np.bincount(codes, weights=land[inside], minlength=area.size)

    # Rows of the band, in the band's order
    return area.reshape(last - first + 1, n_lon)[grid_rows - first]


# -----------------------------
# Boxes
# -----------------------------

def box_means(series, weights, rows):
    """Weighted mean over each box in one row of boxes: month x box.

    `rows` are the band rows of this row of boxes. Cells with zero weight
    (no data, no people or no land) drop out, and the weights are
    renormalized over the rest, as for admin units.
    """

    block = series[:, rows, :].astype("float64")
    weight = weights[rows, :]
    block = np.where(weight > 0, block, 0.0)

    k = len(rows)
    weight = weight.reshape(k, -1, BOX)
    total = np.einsum("tkbj,kbj->tb", block.reshape(block.shape[0], k, -1, BOX), weight)
    weight_sum = weight.sum(axis=(0, 2))
    with np.errstate(invalid="ignore", divide="ignore"):
        return total / weight_sum, weight_sum


# -----------------------------
# Statistics
# -----------------------------

def correlation(x, y):
    """Pearson correlation down the first axis, one per unit."""

    x = x - x.mean(axis=0)
    y = y - y.mean(axis=0)
    with np.errstate(invalid="ignore", divide="ignore"):
        return (x * y).sum(axis=0) / np.sqrt((x * x).sum(axis=0) * (y * y).sum(axis=0))


def unit_stats(rain, flow, flow_input):
    """Statistics for month x unit arrays with complete data."""

    n_years = rain.shape[0] // 12
    rain_years = rain.reshape(n_years, 12, -1)
    flow_years = flow.reshape(n_years, 12, -1)

    rain_mean = rain.mean(axis=0)
    flow_mean = flow.mean(axis=0)

    # Peak month = the calendar month with the highest 1950-2025 mean; ties go
    # to the earlier month, as which.max does in 01_rain_vs_flow_figures.R
    rain_peak = rain_years.mean(axis=0).argmax(axis=0) + 1
    flow_peak = flow_years.mean(axis=0).argmax(axis=0) + 1
    peak_shift = (flow_peak - rain_peak) % 12
    peak_shift[peak_shift > 6] -= 12

    # tp_total minus the flow input is the month's change in snow water
    # equivalent; a rise is precipitation stored as snow. Summing the monthly
    # rises misses snow that falls and melts within one month.
    with np.errstate(invalid="ignore", divide="ignore"):
        snow_share = np.maximum(rain - flow_input, 0).sum(axis=0) / rain.sum(axis=0)
        upstream_ratio = flow_mean / rain_mean

    return {
        "rain_mean": rain_mean,
        "flow_mean": flow_mean,
        "upstream_ratio": upstream_ratio,
        "corr_month": correlation(rain, flow),
        "corr_drought": correlation(rain_years.mean(axis=1), flow_years.mean(axis=1)),
        "corr_flood": correlation(rain_years.max(axis=1), flow_years.max(axis=1)),
        "rain_peak_month": rain_peak,
        "flow_peak_month": flow_peak,
        "peak_shift": peak_shift,
        "snow_share": snow_share,
    }


# -----------------------------
# Process one band
# -----------------------------

def main():
    args = arguments()
    stats_path = OUTPUT_DIR / f"box_stats_band{args.band}.csv"
    summary_path = OUTPUT_DIR / f"band_summary_band{args.band}.csv"

    # Skip an existing band unless overwrite is requested
    if stats_path.is_file() and not args.overwrite:
        print(f"existing file kept: {stats_path}")
        return

    latitude, longitude, flow_input = read_flow_input(args.band)
    print(f"band {args.band}: latitude {latitude[0]:.1f} to {latitude[-1]:.1f}, {len(latitude)} rows")

    # The admin weights' grid (north to south), for the GPW points and to
    # number the boxes from 90N
    grid = read_grid(monthly_climate_file("tp_total", YEARS[0], 1))
    require(np.allclose(grid.longitude, longitude), "Band longitudes differ from the tp_total grid")
    grid_rows, _, inside = grid.point_indices(latitude, np.full(len(latitude), longitude[0]))
    require(inside.all(), "Band latitudes are outside the tp_total grid")
    require(np.allclose(grid.latitude[grid_rows], latitude), "Band latitudes do not match the tp_total grid")
    require(len(longitude) % BOX == 0, "Longitudes do not split into whole boxes")

    flow = read_flow(latitude, longitude)
    rain = read_rainfall(latitude, longitude)
    population = read_population(latitude, longitude)
    land_area = read_land_area(grid, grid_rows)

    # Complete cells have every month of all three inputs. Ocean is NaN in all
    # of them; a land cell with a gap in any month is left out.
    any_flow = np.isfinite(flow).any(axis=0)
    complete = np.isfinite(rain).all(axis=0) & np.isfinite(flow).all(axis=0) & np.isfinite(flow_input).all(axis=0)
    weights = {
        "pop": np.where(complete, population, 0.0),
        "area": np.where(complete, land_area, 0.0),
    }

    # One row of boxes at a time: the band rows in the same box row
    box_row_of = grid_rows // BOX
    n_box_cols = len(longitude) // BOX
    blocks = []
    for box_row in np.unique(box_row_of):
        rows = np.flatnonzero(box_row_of == box_row)
        n_cells = complete[rows].reshape(len(rows), -1, BOX).sum(axis=(0, 2))
        keep = n_cells > 0
        if not keep.any():
            continue

        frame = pd.DataFrame({
            "box_row": box_row,
            "box_col": np.arange(n_box_cols)[keep],
            "lat": np.round(latitude[rows].mean(), 2),
            "lon": np.round(longitude.reshape(-1, BOX).mean(axis=1)[keep], 2),
            "n_cells": n_cells[keep],
            "pop": weights["pop"][rows].reshape(len(rows), -1, BOX).sum(axis=(0, 2))[keep],
            "land_area_km2": weights["area"][rows].reshape(len(rows), -1, BOX).sum(axis=(0, 2))[keep],
        })

        for name, weight in weights.items():
            rain_box, weight_sum = box_means(rain, weight, rows)
            flow_box, _ = box_means(flow, weight, rows)
            input_box, _ = box_means(flow_input, weight, rows)

            # Statistics only where the weights sum above zero
            valid = keep & (weight_sum > 0)
            stats = unit_stats(rain_box[:, valid], flow_box[:, valid], input_box[:, valid])
            for column, values in stats.items():
                full = np.full(n_box_cols, np.nan)
                full[valid] = values
                frame[f"{column}_{name}"] = full[keep]

        blocks.append(frame)

    boxes = pd.concat(blocks, ignore_index=True)
    require(not boxes[["box_row", "box_col"]].duplicated().any(), "Duplicate boxes in output")
    require(boxes["n_cells"].sum() == complete.sum(), "Box cell counts do not add up to the complete cells")
    atomic_csv(boxes, stats_path)

    summary = pd.DataFrame({
        "band": [args.band],
        "lat_min": [latitude[0]],
        "lat_max": [latitude[-1]],
        "n_cells": [complete.size],
        "n_cells_with_flow": [int(any_flow.sum())],
        "n_cells_complete": [int(complete.sum())],
        "n_boxes": [len(boxes)],
        "n_boxes_pop": [int(boxes["rain_mean_pop"].notna().sum())],
        "n_boxes_area": [int(boxes["rain_mean_area"].notna().sum())],
        "pop_total": [population.sum()],
        "pop_complete": [population[complete].sum()],
        "land_area_total_km2": [land_area.sum()],
        "land_area_complete_km2": [land_area[complete].sum()],
    })
    atomic_csv(summary, summary_path)

    # Summary for the log
    print(summary.T.to_string(header=False))
    print(boxes.drop(columns=["box_row", "box_col", "lat", "lon"]).describe().T.to_string())
    print(f"created: {stats_path}")


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
