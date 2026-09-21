#!/usr/bin/env python3
"""
02_aggregate_daily.py

Aggregate one year of CHIRPS precipitation to admin units.

Reads daily CHIRPS precipitation and the fixed CHIRPS weights built by
`01_make_weights.py`. Writes daily, monthly, and annual admin files.

CHIRPS is precipitation only. Daily values are in mm/day on a 0.05-degree grid.
Precipitation powers are calculated at the grid-cell level first, then averaged
within each admin unit using population and area weights.

CHIRPS does not cover the whole globe. The selected country should be fully
inside the CHIRPS latitude band.

Some small coastal or island polygons are assigned CHIRPS cells masked in the
raw precipitation file. For countries listed in `settings.py`, copy values from
a nearby finite CHIRPS cell.

Monthly values require every day in the month. Annual values require all 12
months.
"""

# -----------------------------
# Packages
# -----------------------------

import argparse
import calendar
import os
import sys

from netCDF4 import Dataset, num2date
import numpy as np
import pandas as pd
from scipy import sparse

from common import (
    CheckError,
    POWERS,
    atomic_csv,
    chirps_columns,
    chirps_paths,
    ensure_region_id,
    read_grid,
    require,
)
from settings import admin_file, climate_file, country, weights_file


# -----------------------------
# Arguments
# -----------------------------


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", required=True)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--block-days", type=int, default=31)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Weights and Inputs
# -----------------------------


def load_weights(spec, grid):
    # The fixed admin-to-CHIRPS weights are built once and reused for all years.
    require(weights_file(spec).is_file(), f"Missing weights: {weights_file(spec)}")
    require(admin_file(spec).is_file(), f"Missing admin summary: {admin_file(spec)}")

    # Read admin IDs as strings so leading zeros are preserved.
    dtype = {column: "string" for column in spec.id_columns}
    weights = ensure_region_id(pd.read_csv(weights_file(spec), dtype=dtype), spec)
    admins = ensure_region_id(pd.read_csv(admin_file(spec), dtype=dtype), spec)
    admins = admins.sort_values("region_id").reset_index(drop=True)

    # grid_row/grid_column are CHIRPS cell addresses from the grid-read year.
    # They must still point to the same cells in this year's CHIRPS file.
    require(not admins.region_id.duplicated().any(), "Admin summary has duplicate IDs")
    require(
        not weights.duplicated(["region_id", "grid_row", "grid_column"]).any(),
        "Weights have duplicate admin-grid rows",
    )

    rows = weights.grid_row.to_numpy(dtype="int64")
    columns = weights.grid_column.to_numpy(dtype="int64")
    require(((rows >= 0) & (rows < len(grid.latitude))).all(), "Weight row is outside CHIRPS")
    require(((columns >= 0) & (columns < len(grid.longitude))).all(), "Weight column is outside CHIRPS")

    # Check coordinates as well as row/column indices.
    # This catches a shifted CHIRPS grid even if the array shape is unchanged.
    require(np.allclose(weights.latitude, grid.latitude[rows]), "Weight latitudes differ from CHIRPS")
    require(np.allclose(weights.longitude, grid.longitude[columns]), "Weight longitudes differ from CHIRPS")

    # Convert each CHIRPS row/column pair to one flattened cell index.
    # Several admins can use the same CHIRPS cell, so read each cell once.
    flat = rows * len(grid.longitude) + columns
    unique_flat, cell_number = np.unique(flat, return_inverse=True)
    admin_number = pd.Series(
        np.arange(len(admins)), index=admins.region_id
    ).loc[weights.region_id].to_numpy()
    matrices = {}
    for column, label in (("popwt", "pop"), ("areawt", "area")):
        # Sparse matrices aggregate all admins with one matrix multiplication.
        # Population and area weights are checked separately.
        values = pd.to_numeric(weights[column], errors="raise").to_numpy()
        require(np.isfinite(values).all() and (values >= 0).all(), f"Invalid {column}")
        matrix = sparse.coo_matrix(
            (values, (admin_number, cell_number)),
            shape=(len(admins), len(unique_flat)),
        ).tocsr()
        matrix.sum_duplicates()
        matrices[label] = matrix
        sums = np.asarray(matrix.sum(axis=1)).ravel()
        covered = sums > 0
        require(np.allclose(sums[covered], 1), f"{column} does not sum to one")
    return admins, unique_flat, matrices


def dates(dataset, year):
    # CHIRPS files must contain every calendar day exactly once and in order.
    # Monthly and annual aggregation depend on this being complete.
    require("time" in dataset.variables, "CHIRPS file has no time variable")
    time = dataset.variables["time"]
    decoded = num2date(
        time[:],
        time.units,
        calendar=getattr(time, "calendar", "standard"),
        only_use_cftime_datetimes=False,
        only_use_python_datetimes=True,
    )
    found = pd.DatetimeIndex([value.isoformat()[:10] for value in decoded])
    expected = pd.date_range(f"{year}-01-01", f"{year}-12-31", freq="D")
    require(found.equals(expected), f"Daily dates are incomplete for {year}")
    return found


def open_precipitation(year, grid):
    # Each CHIRPS file should be one complete year of daily mm/day precipitation.
    path = climate_file(year)
    require(path.is_file(), f"Missing CHIRPS input: {path}")
    data = Dataset(path)
    try:
        require("precip" in data.variables, f"{path} has no precip variable")
        variable = data.variables["precip"]
        days = 366 if calendar.isleap(year) else 365
        require(
            variable.shape == (days, len(grid.latitude), len(grid.longitude)),
            f"Unexpected precip shape for {path}: {variable.shape}",
        )
        require(getattr(variable, "units", None) == "mm/day", f"Unexpected precip units for {path}")
        return data, variable
    except Exception:
        data.close()
        raise


# -----------------------------
# Aggregation
# -----------------------------


def nearest_valid_cells(variable, flat_indices, grid, max_radius=20):
    # Used only for countries configured with nearest_valid_cell.
    # Some tiny coastal/island polygons get weights on CHIRPS cells that are
    # masked in the raw precipitation file.
    # Search outward in CHIRPS grid-cell distance and use the nearest finite
    # cell within the country-specific radius.
    first_day = np.ma.asarray(variable[0])
    finite = np.isfinite(np.ma.filled(first_day, np.nan))
    n_lon = len(grid.longitude)
    fallback = {}
    for flat in flat_indices:
        row = int(flat // n_lon)
        column = int(flat % n_lon)
        if finite[row, column]:
            continue
        best = None
        best_distance = None
        for radius in range(1, max_radius + 1):
            row_min = max(0, row - radius)
            row_max = min(finite.shape[0], row + radius + 1)
            col_min = max(0, column - radius)
            col_max = min(finite.shape[1], column + radius + 1)
            window = finite[row_min:row_max, col_min:col_max]
            if not window.any():
                continue
            rows, columns = np.nonzero(window)
            rows = rows + row_min
            columns = columns + col_min
            distance = np.hypot(rows - row, columns - column)
            pick = int(np.argmin(distance))
            best = rows[pick] * n_lon + columns[pick]
            best_distance = float(distance[pick])
            break
        require(best is not None, f"No finite CHIRPS neighbor within {max_radius} cells")
        fallback[int(flat)] = (int(best), best_distance)
    return fallback


def read_cells(variable, start, stop, flat_indices, fallback):
    # Read only CHIRPS cells used by at least one admin unit.
    # Replace only the listed masked source cells with their nearby finite cell.
    values = np.ma.asarray(variable[start:stop])
    values = np.ma.filled(values, np.nan).astype("float64", copy=False)
    flattened = values.reshape(stop - start, -1)
    block = flattened[:, flat_indices].copy()
    if fallback:
        position = {int(flat): index for index, flat in enumerate(flat_indices)}
        for source, (nearest, _) in fallback.items():
            block[:, position[source]] = flattened[:, nearest]
    return block


def aggregate_powers(values, matrix):
    # Take precipitation powers at the grid-cell level before admin averaging.
    # For each day, drop missing CHIRPS cells and renormalize the remaining weights.
    # If no weighted cell is finite, the admin-day stays missing.
    valid = np.isfinite(values)
    denominator = np.asarray(matrix @ valid.T).T
    result = {}
    for power in POWERS:
        transformed = np.where(valid, np.power(values, power), 0)
        numerator = np.asarray(matrix @ transformed.T).T
        answer = np.full(numerator.shape, np.nan)
        np.divide(numerator, denominator, out=answer, where=denominator > 0)
        result[power] = answer
    return result


def daily_frame(block_dates, admins, values, spec, columns):
    # The daily file is written block by block.
    # This frame only covers the current block of dates.
    days = len(block_dates)
    count = len(admins)
    frame = pd.DataFrame({
        "date": np.repeat(block_dates.strftime("%Y-%m-%d"), count),
        "region_id": np.tile(admins.region_id, days),
    })
    for column in spec.id_columns:
        frame[column] = np.tile(admins[column], days)
    for name in columns:
        frame[name] = values[name].reshape(-1)
    return frame


def summary_frames(year, admins, monthly_sum, monthly_count, spec, columns):
    # Monthly values are sums of daily admin values.
    # Keep a month only when every expected day is present.
    # Annual values are sums of the 12 complete monthly values.
    month_labels = [f"{year}-{month:02d}" for month in range(1, 13)]
    days_in_month = np.array([
        calendar.monthrange(year, month)[1] for month in range(1, 13)
    ])[:, None]
    monthly_values = {}
    for name in columns:
        monthly_values[name] = np.where(monthly_count[name] == days_in_month, monthly_sum[name], np.nan)
    n_admins = len(admins)
    monthly = pd.DataFrame({
        "month": np.repeat(month_labels, n_admins),
        "region_id": np.tile(admins.region_id, 12),
    })
    annual = pd.DataFrame({"year": year, "region_id": admins.region_id})
    for column in spec.id_columns:
        monthly[column] = np.tile(admins[column], 12)
        annual[column] = admins[column]
    for name in columns:
        monthly[name] = monthly_values[name].reshape(-1)
        complete = np.isfinite(monthly_values[name]).all(axis=0)
        # Incomplete years stay missing for that admin and variable.
        annual[name] = np.where(complete, np.nansum(monthly_values[name], axis=0), np.nan)
    return monthly, annual


# -----------------------------
# Main
# -----------------------------


def main():
    args = arguments()
    spec = country(args.country)
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")
    require(args.block_days > 0, "block-days must be positive")
    paths = chirps_paths(spec, args.year)
    if all(path.is_file() for path in paths.values()) and not args.overwrite:
        print(f"existing files kept for {spec.code} {args.year}")
        return

    # Read the fixed weights and the CHIRPS grid they should match.
    grid = read_grid(climate_file(spec.pilot_year))
    admins, flat_indices, matrices = load_weights(spec, grid)
    columns = chirps_columns()

    # Write daily blocks to a temporary file so the full daily panel does not
    # sit in memory. Keep the final daily filename untouched until the full year
    # finishes.
    temporary = paths["daily"].with_suffix(".tmp.csv")
    paths["daily"].parent.mkdir(parents=True, exist_ok=True)
    if temporary.exists():
        temporary.unlink()
    monthly_sum = {name: np.zeros((12, len(admins))) for name in columns}
    monthly_count = {name: np.zeros((12, len(admins)), dtype="int16") for name in columns}

    try:
        # Open one year of CHIRPS and check that the daily sequence is complete.
        data, variable = open_precipitation(args.year, grid)
        all_dates = dates(data, args.year)

        # Optional masked-cell replacement for countries listed in settings.py.
        fallback = {}
        if spec.masked_cell_rule == "nearest_valid_cell":
            # Some small coastal/island polygons are assigned CHIRPS cells that
            # are masked in the raw precipitation file. Use a nearby finite
            # CHIRPS cell for the countries listed this way in settings.py.
            fallback = nearest_valid_cells(
                variable, flat_indices, grid, max_radius=spec.masked_cell_max_radius
            )
            if fallback:
                farthest = max(distance for _, distance in fallback.values())
                print(
                    f"{spec.code} {args.year}: nearest-valid fallback "
                    f"cells={len(fallback)} max_distance_cells={farthest:.1f}",
                    flush=True,
                )
        elif spec.masked_cell_rule != "keep_missing":
            require(False, f"Unknown masked-cell rule: {spec.masked_cell_rule}")

        # Process the year in blocks while accumulating monthly sums and
        # valid-day counts.
        for start in range(0, len(all_dates), args.block_days):
            stop = min(start + args.block_days, len(all_dates))
            block_dates = all_dates[start:stop]
            months = block_dates.month.to_numpy() - 1

            block = read_cells(variable, start, stop, flat_indices, fallback)
            finite = block[np.isfinite(block)]

            # Sanity-check the CHIRPS values used by these admins in this block.
            require(len(finite) > 0, "CHIRPS block has no finite weighted cells")
            require(finite.min() >= 0, "CHIRPS contains negative precipitation")

            values = {}
            for weighting in ("pop", "area"):
                # Aggregate population- and area-weighted precipitation powers.
                powers = aggregate_powers(block, matrices[weighting])
                for power, result in powers.items():
                    name = f"prcp_{weighting}_p{power}"
                    values[name] = result
                    for month in np.unique(months):
                        # Counts show whether each admin-month has every day.
                        keep = months == month
                        month_values = result[keep]
                        monthly_sum[name][month] += np.nansum(month_values, axis=0)
                        monthly_count[name][month] += np.isfinite(month_values).sum(axis=0)

            # Append this daily block to the temporary CSV.
            frame = daily_frame(block_dates, admins, values, spec, columns)
            frame.to_csv(
                temporary,
                mode="w" if start == 0 else "a",
                header=start == 0,
                index=False,
                float_format="%.15g",
            )
            print(f"{spec.code} {args.year}: days {start + 1}-{stop}", flush=True)
        data.close()

        # After the full year finishes, write monthly and annual files and move
        # the complete temporary daily file into place.
        monthly, annual = summary_frames(args.year, admins, monthly_sum, monthly_count, spec, columns)
        paths["monthly"].parent.mkdir(parents=True, exist_ok=True)
        paths["annual"].parent.mkdir(parents=True, exist_ok=True)

        os.replace(temporary, paths["daily"])
        atomic_csv(monthly, paths["monthly"])
        atomic_csv(annual, paths["annual"])
        print(f"created={paths['daily']}")
        print(f"created={paths['monthly']}")
        print(f"created={paths['annual']}")
    except Exception:
        if temporary.exists():
            temporary.unlink()
        raise


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Put the failed check in the Slurm log before the job exits.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
