#!/usr/bin/env python3
"""
02_aggregate_prcp_temp.py

Aggregate one year of ERA5-Land climate data to admin units.

This script reads monthly global ERA5-Land files and aggregates the daily
values to administrative units using the fixed population and land-area weights
created by `01_make_weights.py`.

For each climate variable, powers 1 through 5 are calculated at the ERA5-Land
grid-cell level before spatial aggregation. Both population-weighted and
area-weighted values are kept.

Inputs:
- monthly global ERA5-Land `tp_total`, `tmean`, and `tmax` NetCDF files
- admin-grid weights from `01_make_weights.py`

Outputs:
- daily admin climate CSV
- monthly admin climate CSV
- annual admin climate CSV

Missing climate cells are handled separately for each day. If some weighted
cells are missing, the remaining weights are renormalized over the cells with
finite climate values.

Monthly values are kept only when every day in the month is present.
Annual values are kept only when all 12 monthly values are present.

Run this through Slurm for full country-year jobs.
"""

# -----------------
# Packages
# -----------------


import argparse
import calendar
from contextlib import ExitStack
import os
import sys

from netCDF4 import Dataset
import numpy as np
import pandas as pd

from common import (
    CLIMATE_VARIABLES,
    POWERS,
    admin_climate_columns,
    admin_climate_paths,
    atomic_csv,
    cell_window,
    load_weights,
    month_dates,
    read_cells_window,
    read_grid,
    require,
)
from settings import (
    climate_file,
    country,
    monthly_climate_file,
)


# -----------------------------
# Arguments and output paths
# -----------------------------


def arguments():
    # `block-days` controls how many daily rasters are read at once
    # Smaller blocks use less memory but require more reads from the NetCDF files
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", required=True)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--block-days", type=int, default=31)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Check climate files
# -----------------------------


def open_month_variable(stack, short_name, year, month, grid):
    # Open one monthly global climate file and check the variable, units, and grid.
    source_name, expected_units = CLIMATE_VARIABLES[short_name]
    path = monthly_climate_file(source_name, year, month)
    require(path.is_file(), f"Missing input: {path}")
    data = stack.enter_context(Dataset(path))
    require(source_name in data.variables, f"{path} has no {source_name}")
    variable = data.variables[source_name]
    days = calendar.monthrange(year, month)[1]

    # Every monthly file should have one raster per day on the global grid.
    require(
        variable.shape == (days, len(grid.latitude), len(grid.longitude)),
        f"Unexpected shape for {path}: {variable.shape}",
    )
    require(getattr(variable, "units", None) == expected_units, f"Unexpected units for {path}")

    # The weights store ERA5-Land cells by row and column number.
    # Check that this monthly file uses the same global grid before using them.
    latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
    longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
    require(np.allclose(longitude, grid.longitude), f"Longitudes differ from the weights grid: {path}")
    require(np.allclose(latitude, grid.latitude), f"Latitudes differ from the weights grid: {path}")

    return data, variable


# -----------------------------
# Daily spatial aggregation
# -----------------------------


def aggregate_powers(values, matrix):
    # `values` is day x ERA5-Land cell
    # `matrix` contains population or area weights for all admin units

    # Missing climate cells are handled separately for each admin/day
    # The denominator is the total weight attached to cells with finite values
    valid = np.isfinite(values)
    denominator = np.asarray(matrix @ valid.T).T

    result = {}
    for power in POWERS:
        # Apply the polynomial transformation before spatial aggregation
        transformed = np.where(valid, np.power(values, power), 0)

        # Weighted sum across ERA5-Land cells for every admin/day
        numerator = np.asarray(matrix @ transformed.T).T
        answer = np.full(numerator.shape, np.nan)

        # Divide by the finite-cell weight sum so weights are renormalized when
        # only part of an admin unit has valid climate data on a given day
        # If no weighted cell is finite, the admin/day stays missing
        np.divide(numerator, denominator, out=answer, where=denominator > 0)
        result[power] = answer

    return result


def daily_frame(block_dates, admins, values, spec, columns):
    # Convert one block of day x admin arrays to one row per admin unit and date
    days = len(block_dates)
    count = len(admins)

    frame = pd.DataFrame({
        "date": np.repeat(block_dates.strftime("%Y-%m-%d"), count),
        "region_id": np.tile(admins.region_id, days),
    })

    # Repeat the country-specific admin IDs for every day
    for column in spec.id_columns:
        frame[column] = np.tile(admins[column], days)

    # Rows are ordered by date, then admin unit
    # Flatten the climate arrays in the same order so values line up with rows
    for name in columns:
        frame[name] = values[name].reshape(-1)

    return frame


# -----------------------------
# Monthly and annual aggregation
# -----------------------------


def summary_frames(year, admins, monthly_sum, monthly_count, spec, columns):
    # Daily values have already been accumulated into monthly sums
    # Keep a monthly value only when every day in that month is available
    # Keep an annual value only when all 12 monthly values are available
    month_labels = [f"{year}-{month:02d}" for month in range(1, 13)]
    days_in_month = np.array([
        calendar.monthrange(year, month)[1] for month in range(1, 13)
    ])[:, None]

    monthly_values = {}
    for name in columns:
        # monthly_count records the number of finite daily values for each
        # month and admin unit
        monthly_values[name] = np.where(
            monthly_count[name] == days_in_month,
            monthly_sum[name],
            np.nan,
        )

    n_admins = len(admins)

    # Monthly output has one row per month and admin unit
    monthly = pd.DataFrame({
        "month": np.repeat(month_labels, n_admins),
        "region_id": np.tile(admins.region_id, 12),
    })

    # Annual output has one row per admin unit
    annual = pd.DataFrame({
        "year": year,
        "region_id": admins.region_id,
    })

    for column in spec.id_columns:
        monthly[column] = np.tile(admins[column], 12)
        annual[column] = admins[column]

    for name in columns:
        monthly[name] = monthly_values[name].reshape(-1)

        # Require all 12 months before calculating the annual value
        complete = np.isfinite(monthly_values[name]).all(axis=0)
        annual[name] = np.where(
            complete, np.nansum(monthly_values[name], axis=0), np.nan
        )

    return monthly, annual


# -----------------------------
# Process one country-year
# -----------------------------


def main():
    args = arguments()
    spec = country(args.country)

    # Keep requests inside the year range defined for this country
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")
    require(args.block_days > 0, "block-days must be positive")

    paths = admin_climate_paths(spec, args.year)

    # Skip a completed country-year unless overwrite is requested
    if all(path.is_file() for path in paths.values()) and not args.overwrite:
        print(f"existing files kept for {spec.code} {args.year}")
        return

    # Load the ERA5-Land grid and check that the stored weights still match it
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)
    columns = admin_climate_columns()

    # The daily output can be large, so write it block by block instead of
    # keeping the full year of admin-day rows in memory
    # Use a temporary file so a failed job does not leave a partial final CSV
    temporary = paths["daily"].with_suffix(".tmp.csv")
    paths["daily"].parent.mkdir(parents=True, exist_ok=True)
    if temporary.exists():
        temporary.unlink()

    # Monthly sums and counts are updated as each daily block is processed
    # Arrays are month x admin unit
    months = 12
    n_admins = len(admins)
    monthly_sum = {
        name: np.zeros((months, n_admins)) for name in columns
    }
    monthly_count = {
        name: np.zeros((months, n_admins), dtype="int16") for name in columns
    }

    try:
        # The weights use global row/column addresses
        # Read only the rectangle that contains this country's weighted cells
        row_min, row_max, col_min, col_max, local_flat = cell_window(flat_indices, grid)

        processed_days = 0

        for month in range(1, 13):
            with ExitStack() as stack:
                # Open the three global monthly files for this calendar month.
                opened = {
                    name: open_month_variable(stack, name, args.year, month, grid)
                    for name in CLIMATE_VARIABLES
                }

                # Use precipitation as the reference date sequence for the month.
                month_days = month_dates(opened["prcp"][0], args.year, month)

                # All climate variables must have exactly the same daily dates.
                for name, (dataset, _) in opened.items():
                    require(
                        month_dates(dataset, args.year, month).equals(month_days),
                        f"{name} dates differ from precipitation in {args.year}-{month:02d}",
                    )

                # Process this month in blocks to keep memory use manageable.
                for start in range(0, len(month_days), args.block_days):
                    stop = min(start + args.block_days, len(month_days))
                    values = {}

                    for variable, (_, source) in opened.items():
                        # Read only the global grid cells used by this country.
                        raw = read_cells_window(
                            source, start, stop,
                            row_min, row_max, col_min, col_max,
                            local_flat,
                        )

                        # Catch obvious unit problems or corrupted inputs before aggregation.
                        if variable == "prcp":
                            require(np.nanmin(raw) >= -1e-7, "Negative precipitation found")
                        else:
                            require(
                                np.nanmin(raw) > -100 and np.nanmax(raw) < 70,
                                f"Implausible {variable} found",
                            )

                        # Aggregate each climate variable with both population and area weights.
                        for weighting, matrix in matrices.items():
                            # Powers are applied at the grid-cell level before spatial averaging.
                            for power, answer in aggregate_powers(raw, matrix).items():
                                values[f"{variable}_{weighting}_p{power}"] = answer

                    block_dates = month_days[start:stop]

                    # Write the current block as admin-day rows.
                    frame = daily_frame(block_dates, admins, values, spec, columns)
                    frame.to_csv(
                        temporary,
                        mode="w" if processed_days == 0 else "a",
                        header=processed_days == 0,
                        index=False,
                        float_format="%.15g",
                    )

                    # Update monthly totals and counts from the current block.
                    # The counts are later used to require complete months.
                    for name, answer in values.items():
                        monthly_sum[name][month - 1] += np.nansum(answer, axis=0)
                        monthly_count[name][month - 1] += np.isfinite(answer).sum(axis=0)

                    processed_days += len(block_dates)
                    print(
                        f"{spec.code} {args.year}-{month:02d}: days {start + 1}-{stop}",
                        flush=True,
                    )

        # Convert the accumulated daily values to monthly and annual outputs
        monthly, annual = summary_frames(
            args.year, admins, monthly_sum, monthly_count, spec, columns
        )

        # The daily file should have exactly one row per admin unit per day
        expected_days = 366 if calendar.isleap(args.year) else 365
        require(
            sum(1 for _ in open(temporary, encoding="utf-8")) - 1
            == expected_days * n_admins,
            "Daily row count is wrong",
        )

        # Write final outputs only after the daily row-count check passes
        atomic_csv(monthly, paths["monthly"])
        atomic_csv(annual, paths["annual"])
        os.replace(temporary, paths["daily"])

        for label, path in paths.items():
            print(f"created {label}: {path}")

    except Exception:
        # Remove a partial daily file if anything fails during the aggregation
        if temporary.exists():
            temporary.unlink()
        raise


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
    # Print failed checks clearly and make Slurm mark the job as failed
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
