#!/usr/bin/env python3
"""
03_aggregate_monthly_precip.py

Aggregate ERA5-Land daily precipitation to U.S. state-month values.

Reads one year of daily ERA5-Land `tp_total` and the state-grid weights built
by `01_make_state_weights.py`. Writes one state-month CSV with monthly
precipitation powers.

Inputs:
- raw daily ERA5-Land USA `tp_total` NetCDF for one year
- state-grid weights from `01_make_state_weights.py`

Outputs:
- state-month CSV with population- and area-weighted precipitation powers

For each day, precipitation powers are calculated in each grid cell first:

    prcp, prcp^2, prcp^3, prcp^4, prcp^5

Those daily grid-cell powers are then averaged across states using population
and area weights. Monthly values are sums of the daily state values. A
state-month is left missing unless all days in that month are present.
"""


# ------------------
# Packages
# ------------------

import argparse
import calendar
from pathlib import Path
import sys

from netCDF4 import Dataset, num2date
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
PRECIP_VARIABLE = "tp_total"
PRECIP_UNITS = "mm"
POWERS = range(1, 6)
GRID_FILE = RAW_ROOT / "tp_total/era5land_usa_tp_total_1968.nc4"
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

# Output names mirror the admin aggregation: variable, weighting, and power.
OUTPUT_VARIABLES = [f"prcp_{weighting}_p{power}" for weighting in ("pop", "area") for power in POWERS]


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    # One array task processes one year.
    parser = argparse.ArgumentParser(description=__doc__)

    # Calendar year in the annual daily precipitation NetCDF file.
    parser.add_argument("--year", type=int, required=True)

    # Number of daily slices to read at once from the NetCDF file.
    parser.add_argument("--block-days", type=int, default=31)

    # Replace the yearly output CSV if it already exists.
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Inputs
# -----------------------------

def load_weights(grid):
    # Weights come from 01_make_state_weights.py.
    require(WEIGHT_FILE.is_file(), f"Missing weight file: {WEIGHT_FILE}")
    require(ADMIN_FILE.is_file(), f"Missing admin file: {ADMIN_FILE}")

    admins = pd.read_csv(ADMIN_FILE)
    weights = pd.read_csv(WEIGHT_FILE)
    require(not admins["region_id"].duplicated().any(), "Duplicate states in admin file")

    # Flatten row/column pairs so each used ERA5-Land cell is read once.
    n_longitude = len(grid.longitude)
    weights["flat"] = weights["grid_row"] * n_longitude + weights["grid_column"]
    flat_indices = np.array(sorted(weights["flat"].unique()), dtype="int64")
    flat_to_column = {int(flat): number for number, flat in enumerate(flat_indices)}
    admin_to_row = {region_id: number for number, region_id in enumerate(admins.region_id)}

    # The same state weights are reused for every day and every precip power.
    # Sparse matrices aggregate all states without looping over them.
    rows = weights["region_id"].map(admin_to_row).to_numpy(dtype="int64")
    columns = weights["flat"].map(flat_to_column).to_numpy(dtype="int64")
    matrices = {}
    for weight_column in ["popwt", "areawt"]:
        matrix = sparse.coo_matrix(
            (weights[weight_column].to_numpy("float64"), (rows, columns)),
            shape=(len(admins), len(flat_indices)),
        ).tocsr()
        matrix.sum_duplicates()
        sums = np.asarray(matrix.sum(axis=1)).ravel()
        require(np.allclose(sums, 1), f"{weight_column} does not sum to one")
        matrices[weight_column] = matrix

    return admins, flat_indices, matrices


def dates(data, year):
    # Monthly totals are only valid if every calendar day is present and ordered.
    require("valid_time" in data.variables, "Precip file has no valid_time")
    time = data.variables["valid_time"]
    decoded = num2date(
        time[:],
        time.units,
        calendar=getattr(time, "calendar", "proleptic_gregorian"),
        only_use_cftime_datetimes=False,
        only_use_python_datetimes=True,
    )
    found = pd.DatetimeIndex([value.isoformat()[:10] for value in decoded])
    expected = pd.date_range(f"{year}-01-01", f"{year}-12-31", freq="D")
    require(found.equals(expected), f"Daily dates are incomplete for {year}")
    return found


def open_precip(year, grid):
    # Open the annual precipitation file and check that it matches the grid.
    path = RAW_ROOT / PRECIP_VARIABLE / f"era5land_usa_{PRECIP_VARIABLE}_{year}.nc4"
    require(path.is_file(), f"Missing precipitation input: {path}")

    data = Dataset(path)
    if PRECIP_VARIABLE not in data.variables:
        data.close()
        require(False, f"{path} has no {PRECIP_VARIABLE}")

    variable = data.variables[PRECIP_VARIABLE]
    days = 366 if calendar.isleap(year) else 365
    require(
        variable.shape == (days, len(grid.latitude), len(grid.longitude)),
        f"Unexpected precipitation shape for {path}: {variable.shape}",
    )
    require(getattr(variable, "units", None) == PRECIP_UNITS, f"Unexpected precipitation units in {path}")

    latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
    longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
    require(np.allclose(longitude, grid.longitude, atol=1e-6), f"Unexpected longitude grid in {path}")

    # Some raw ERA5-Land files store latitude in the opposite row order.
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
    # Read daily precipitation, flip latitude if needed, and keep only weighted cells.
    values = np.ma.asarray(variable[start:stop])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    if flip_latitude:
        values = values[:, ::-1, :]
    return values.reshape(values.shape[0], -1)[:, flat_indices]


def aggregate_power(values, matrix, power):
    # Take powers at the grid-cell level first, then average to the state.
    # Missing cells are dropped and weights are renormalized over finite cells.
    valid = np.isfinite(values)
    transformed = np.where(valid, np.power(values, power), 0)
    denominator = np.asarray(matrix @ valid.T).T
    numerator = np.asarray(matrix @ transformed.T).T
    answer = np.full(numerator.shape, np.nan)
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def monthly_measures(variable, year, all_dates, flat_indices, matrices, block_days, flip_latitude):
    # Store monthly sums and finite-day counts for each output variable.
    n_states = matrices["popwt"].shape[0]
    monthly_sum = {name: np.zeros((12, n_states)) for name in OUTPUT_VARIABLES}
    monthly_count = {name: np.zeros((12, n_states), dtype="int16") for name in OUTPUT_VARIABLES}

    # Read the annual file in blocks, then add daily state values to months.
    for start in range(0, len(all_dates), block_days):
        stop = min(start + block_days, len(all_dates))
        raw = read_cells(variable, start, stop, flat_indices, flip_latitude)
        finite = raw[np.isfinite(raw)]

        # Basic sanity checks on the ERA5-Land precipitation values in this block.
        require(len(finite) > 0, "Precipitation block has no finite weighted cells")
        require(finite.min() >= 0, "Negative precipitation found")
        require(finite.max() < 2000, "Implausibly high daily precipitation found")

        months = all_dates[start:stop].month.to_numpy() - 1
        for weighting, matrix in (("pop", matrices["popwt"]), ("area", matrices["areawt"])):
            for power in POWERS:
                name = f"prcp_{weighting}_p{power}"
                values = aggregate_power(raw, matrix, power)

                # Sum daily state values and count finite days within each month.
                for month in np.unique(months):
                    month_values = values[months == month]
                    monthly_sum[name][month] += np.nansum(month_values, axis=0)
                    monthly_count[name][month] += np.isfinite(month_values).sum(axis=0)

        print(f"days {start + 1}-{stop}", flush=True)

    return monthly_sum, monthly_count


# -----------------------------
# Output
# -----------------------------

def build_output(admins, year, monthly_sum, monthly_count):
    # A state-month is kept only when every calendar day has a finite value.
    n_states = len(admins)
    month_labels = np.arange(1, 13)
    days_in_month = np.array([calendar.monthrange(year, month)[1] for month in month_labels])[:, None]

    # Start with one row for each state-month in the year.
    output = pd.DataFrame({
        "stfips": np.tile(admins["stfips"].to_numpy(), 12),
        "state_abbrev": np.tile(admins["state_abbrev"].to_numpy(), 12),
        "adm_name": np.tile(admins["adm_name"].to_numpy(), 12),
        "region_id": np.tile(admins["region_id"].to_numpy(), 12),
        "year": year,
        "month": np.repeat(month_labels, n_states),
    })

    for name in OUTPUT_VARIABLES:
        # Incomplete state-months stay missing for this precipitation variable.
        complete = monthly_count[name] == days_in_month
        output[name] = np.where(complete, monthly_sum[name], np.nan).reshape(-1)

    columns = [
        "stfips", "state_abbrev", "adm_name", "region_id",
        "year", "month", *OUTPUT_VARIABLES,
    ]
    return output.loc[:, columns]


def check_output(frame):
    # Final checks before writing the yearly state-month file.
    require(not frame[["stfips", "year", "month"]].duplicated().any(), "Duplicate state-month rows")
    require(frame["month"].between(1, 12).all(), "Bad month value")
    require(frame[OUTPUT_VARIABLES].notna().any().all(), "Precipitation output missing")
    require((frame[OUTPUT_VARIABLES] >= 0).all().all(), "Negative precipitation output")


def main():
    args = arguments()
    require(args.block_days > 0, "block-days must be positive")

    # Keep existing yearly files unless the run explicitly asks to replace them.
    path = OUTPUT_DIR / f"era5land_usa_state_month_precip_{args.year}.csv"
    if path.exists() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # Fixed weights determine which ERA5-Land cells need to be read.
    grid = read_grid(GRID_FILE)
    admins, flat_indices, matrices = load_weights(grid)

    # Always close the NetCDF file, including after a failed check.
    data = None
    try:
        data, precip, flip_latitude = open_precip(args.year, grid)
        all_dates = dates(data, args.year)
        monthly_sum, monthly_count = monthly_measures(
            precip, args.year, all_dates, flat_indices, matrices, args.block_days, flip_latitude
        )
        output = build_output(admins, args.year, monthly_sum, monthly_count)
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
