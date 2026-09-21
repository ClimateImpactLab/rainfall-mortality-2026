#!/usr/bin/env python3
"""
02_aggregate_monthly_wind.py

Aggregate ERA5-Land daily wind to U.S. state-month values.

Reads one year of daily ERA5-Land `wind_max` and the state-grid weights built
by `01_make_state_weights.py`. Writes one state-month wind CSV.

This aggregates the ERA5-Land all-weather `wind_max` variable used later in
the comparison with LICRICE tropical-cyclone wind.

Inputs:
- raw daily ERA5-Land USA `wind_max` NetCDF for one year
- state-grid weights from `01_make_state_weights.py`

Outputs:
- state-month CSV with population- and area-weighted monthly maximum wind

For each state-month, the aggregation is:

    daily grid-cell wind -> grid-cell monthly max -> state weighted mean

"""


# ------------------
# Packages
# ------------------

import argparse
import calendar
from pathlib import Path
import sys

from netCDF4 import Dataset
import numpy as np
import pandas as pd
from scipy import sparse


ERA5_ADMIN = Path(__file__).resolve().parents[1] / "era5land_admin"
sys.path.insert(0, str(ERA5_ADMIN))

# Reuse the ERA5-Land grid reader and CSV/check helpers from the admin
# aggregation folder.
from common import CheckError, atomic_csv, read_grid, require  # noqa: E402


# -----------------------------
# Paths
# -----------------------------

RAW_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa")
WIND_VARIABLE = "wind_max"
WIND_UNITS = "m/s"
GRID_FILE = Path(
    "/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/tp_total/"
    "era5land_usa_tp_total_1968.nc4"
)
WEIGHT_DIR = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/"
    "landscan2011/ERA5-LAND/USA_STATE_MONTH"
)
WEIGHT_FILE = WEIGHT_DIR / "era5land_usa_state_month_weights_landscan2011.csv"
ADMIN_FILE = WEIGHT_DIR / "era5land_usa_state_month_admins.csv"
OUTPUT_DIR = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/climate_data/"
    "ERA5-LAND/USA/state_month"
)


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    # One array task processes one year.
    parser = argparse.ArgumentParser(description=__doc__)

    # Calendar year in the annual daily wind NetCDF file.
    parser.add_argument("--year", type=int, required=True)

    # Number of daily slices to read at once from the NetCDF file.
    parser.add_argument("--block-days", type=int, default=31)

    # Replace the yearly output CSV if it already exists.
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Inputs and weights
# -----------------------------

def load_weights(grid):
    # Weights come from 01_make_state_weights.py.
    require(WEIGHT_FILE.is_file(), f"Missing weight file: {WEIGHT_FILE}")
    require(ADMIN_FILE.is_file(), f"Missing admin file: {ADMIN_FILE}")

    admins = pd.read_csv(ADMIN_FILE)
    weights = pd.read_csv(WEIGHT_FILE)
    require(not admins["region_id"].duplicated().any(), "Duplicate states in admin file")

    # grid_row/grid_column identify ERA5-Land cells. Flattening lets each used
    # cell be read once even if many states use it.
    n_longitude = len(grid.longitude)
    weights["flat"] = weights["grid_row"] * n_longitude + weights["grid_column"]
    flat_indices = np.array(sorted(weights["flat"].unique()), dtype="int64")
    flat_to_column = {int(flat): number for number, flat in enumerate(flat_indices)}
    admin_to_row = {region_id: number for number, region_id in enumerate(admins.region_id)}

    # Sparse matrices aggregate all states at once. Keep population and area
    # weights separate because both outputs are used.
    rows = weights["region_id"].map(admin_to_row).to_numpy(dtype="int64")
    columns = weights["flat"].map(flat_to_column).to_numpy(dtype="int64")
    matrices = {}
    for weight_column in ["popwt", "areawt"]:
        matrices[weight_column] = sparse.coo_matrix(
            (weights[weight_column].to_numpy("float64"), (rows, columns)),
            shape=(len(admins), len(flat_indices)),
        ).tocsr()

    return admins, flat_indices, matrices


def open_wind(year, grid):
    # Open the annual wind file and check that it matches the ERA5-Land grid.
    path = RAW_ROOT / WIND_VARIABLE / f"era5land_usa_{WIND_VARIABLE}_{year}.nc4"
    require(path.is_file(), f"Missing wind input: {path}")

    data = Dataset(path)
    if WIND_VARIABLE not in data.variables:
        data.close()
        require(False, f"{path} has no {WIND_VARIABLE}")

    variable = data.variables[WIND_VARIABLE]
    days = 366 if calendar.isleap(year) else 365
    require(
        variable.shape == (days, len(grid.latitude), len(grid.longitude)),
        f"Unexpected wind shape for {path}: {variable.shape}",
    )
    require(getattr(variable, "units", None) == WIND_UNITS, f"Unexpected wind units in {path}")

    latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
    longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
    require(np.allclose(longitude, grid.longitude, atol=1e-6), f"Unexpected longitude grid in {path}")

    # Some raw files store latitude north-to-south, flip only when needed.
    if np.allclose(latitude, grid.latitude, atol=1e-6):
        flip_latitude = False
    elif np.allclose(latitude[::-1], grid.latitude, atol=1e-6):
        flip_latitude = True
    else:
        data.close()
        require(False, f"Unexpected latitude grid in {path}")

    return data, variable, flip_latitude


# -----------------------------
# Monthly aggregation
# -----------------------------

def read_cells(variable, start, stop, flat_indices, flip_latitude):
    # Read daily wind, flip latitude if needed, and keep only weighted cells.
    values = np.ma.asarray(variable[start:stop])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    if flip_latitude:
        values = values[:, ::-1, :]
    return values.reshape(values.shape[0], -1)[:, flat_indices]


def aggregate_with_finite_cells(values, matrix):
    # Drop missing grid cells and renormalize the remaining weights.
    # If no weighted cell is finite, the state value stays missing.
    valid = np.isfinite(values)
    denominator = np.asarray(matrix @ valid.T).T.ravel()
    numerator = np.asarray(matrix @ np.where(valid, values, 0).T).T.ravel()
    answer = np.full(numerator.shape, np.nan)
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def monthly_measures(variable, year, dates, flat_indices, matrices, block_days, flip_latitude):
    # Keep the monthly maximum at the grid-cell level before averaging to states.
    n_cells = len(flat_indices)
    month_max = {month: np.full(n_cells, np.nan) for month in range(1, 13)}

    # Read the annual file in blocks and update each touched month's cell maxima.
    for start in range(0, len(dates), block_days):
        stop = min(start + block_days, len(dates))
        raw = read_cells(variable, start, stop, flat_indices, flip_latitude)

        # Basic sanity check on the raw wind values used in this block.
        require(np.nanmin(raw) >= 0, "Negative wind speed found")
        require(np.nanmax(raw) < 120, "Implausibly high wind speed found")

        block_months = dates[start:stop].month.to_numpy()
        for month in sorted(set(block_months)):
            month_raw = raw[block_months == month]
            finite = np.isfinite(month_raw)
            block_max = np.max(np.where(finite, month_raw, -np.inf), axis=0)
            block_max[~finite.any(axis=0)] = np.nan
            month_max[month] = np.fmax(month_max[month], block_max)

        print(f"days {start + 1}-{stop}", flush=True)

    # Population- and area-weighted state values are both kept.
    rows = []
    for month in range(1, 13):
        rows.append({
            "year": year,
            "month": month,
            "windmax_pop_month": aggregate_with_finite_cells(month_max[month], matrices["popwt"]),
            "windmax_area_month": aggregate_with_finite_cells(month_max[month], matrices["areawt"]),
        })
    return rows


# -----------------------------
# Output
# -----------------------------

def build_output(admins, year, measures):
    # Expand the monthly arrays into a state-month table.
    frames = []
    id_columns = ["stfips", "state_abbrev", "adm_name", "region_id"]
    for item in measures:
        # Attach the same state IDs to each month's population and area wind values.
        frame = admins.loc[:, id_columns].copy()
        frame["year"] = item["year"]
        frame["month"] = item["month"]
        frame["windmax_pop_month"] = item["windmax_pop_month"]
        frame["windmax_area_month"] = item["windmax_area_month"]
        frames.append(frame)

    columns = [
        "stfips", "state_abbrev", "adm_name", "region_id",
        "year", "month", "windmax_pop_month", "windmax_area_month",
    ]
    return pd.concat(frames, ignore_index=True).loc[:, columns]


def check_output(frame):
    # Final checks before writing the yearly state-month file.
    wind_columns = ["windmax_pop_month", "windmax_area_month"]
    require(not frame[["stfips", "year", "month"]].duplicated().any(), "Duplicate state-month rows")
    require(frame["month"].between(1, 12).all(), "Bad month value")
    require(frame[wind_columns].notna().any().all(), "Wind output missing")
    require((frame[wind_columns] >= 0).all().all(), "Negative wind output")
    require((frame[wind_columns] < 120).all().all(), "Implausible wind output")


def main():
    args = arguments()
    require(args.block_days > 0, "block-days must be positive")

    # Keep existing yearly files unless the run explicitly asks to replace them.
    path = OUTPUT_DIR / f"era5land_usa_state_month_wind_{args.year}.csv"
    if path.exists() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # Fixed weights determine which ERA5-Land cells need to be read.
    grid = read_grid(GRID_FILE)
    admins, flat_indices, matrices = load_weights(grid)
    dates = pd.date_range(f"{args.year}-01-01", f"{args.year}-12-31", freq="D")

    # Always close the NetCDF file, including after a failed check.
    data = None
    try:
        data, wind, flip_latitude = open_wind(args.year, grid)
        measures = monthly_measures(
            wind, args.year, dates, flat_indices, matrices, args.block_days, flip_latitude
        )
        output = build_output(admins, args.year, measures)
        check_output(output)
        atomic_csv(output, path)
        print(f"created {path}")
    finally:
        if data is not None:
            data.close()


if __name__ == "__main__":
    # Print clean messages for expected input and output-check failures.
    try:
        main()
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
