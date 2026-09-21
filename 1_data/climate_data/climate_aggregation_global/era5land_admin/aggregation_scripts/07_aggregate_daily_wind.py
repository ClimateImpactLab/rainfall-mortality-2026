#!/usr/bin/env python3
"""
07_aggregate_daily_wind.py

Aggregate daily ERA5-Land wind for one country-year.

This script reads country-month-year ERA5-Land `wind_max` files with daily
values and aggregates daily wind to admin units using the weights created by
`01_make_weights.py`.

Outputs:
- population- and area-weighted daily wind
- population- and area-weighted daily share above 17.5 m/s

ERA5-Land wind captures high wind from any weather system. It can include
tropical cyclones, but it is not limited to them.

This daily file is different from the annual maximum wind file. The annual file
takes each grid cell's maximum wind over the year, then averages those maxima to
the admin unit. This script averages wind to the admin unit separately for each
day, so it can be used to check whether heavy-rain days also had high wind.

The high-wind-share variables give the weighted share of the admin unit above
17.5 m/s on each day. The threshold is about 63 km/h, close to
tropical-storm-force wind.

This script uses the same wind-only fallback as `05_aggregate_annual_wind.py`.
Some small islands have normal climate weights but no finite ERA5-Land wind
values in the cells used by those weights. For wind only, affected weights can
be moved to the nearest finite wind cell within 1.6 degrees.

Inputs:
- country-month-year ERA5-Land `wind_max` NetCDF files with daily values
- admin-grid weights from `01_make_weights.py`
"""

# -----------------
# Packages
# -----------------

import argparse
import os
import sys

import numpy as np
import pandas as pd

from common import (
    CheckError,
    cell_window,
    load_weights,
    read_cells_window,
    read_grid,
    require,
)
from settings import climate_file, country, result_dir
from wind_common import apply_wind_fallback, open_wind_file


# -----------------------------
# Wind settings
# -----------------------------

HIGH_WIND_THRESHOLD = 17.5

OUTPUT_VARIABLES = [
    "windmax_pop_day",
    "windmax_area_day",
    "windshare_17p5_pop_day",
    "windshare_17p5_area_day",
]


# -----------------------------
# Arguments and output paths
# -----------------------------

def arguments():
    # `block-days` controls how many daily wind rasters are read at once
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", required=True)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--block-days", type=int, default=31)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Daily wind aggregation
# -----------------------------

def aggregate_with_finite_cells(raw, matrix):
    # `raw` is day x ERA5-Land cell
    # Average wind over the finite weighted cells for each admin unit and day
    valid = np.isfinite(raw)
    denominator = np.asarray(matrix @ valid.T).T
    numerator = np.asarray(matrix @ np.where(valid, raw, 0).T).T
    answer = np.full(numerator.shape, np.nan)

    # Renormalize the weights when some wind cells are missing
    # Admin-days with no finite weighted cells remain missing
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def aggregate_threshold_share(raw, matrix):
    # Convert each grid cell/day to an indicator for wind above 17.5 m/s
    # The weighted average is therefore the share of the admin unit above the
    # threshold on that day
    valid = np.isfinite(raw)
    high_wind = np.where(valid, raw > HIGH_WIND_THRESHOLD, 0)
    denominator = np.asarray(matrix @ valid.T).T
    numerator = np.asarray(matrix @ high_wind.T).T
    answer = np.full(numerator.shape, np.nan)

    # Example: 0.25 means 25% of the weighted admin unit is above 17.5 m/s
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def block_frame(year, dates, admins, raw, matrices, spec, columns):
    # Build one output block with one row per admin unit and date
    # All admin units for day 1 come first, followed by all admin units for day 2
    n_days = len(dates)
    n_admins = len(admins)

    # Calculate population- and area-weighted daily mean wind and high-wind shares
    values = {
        "windmax_pop_day": aggregate_with_finite_cells(raw, matrices["pop"]),
        "windmax_area_day": aggregate_with_finite_cells(raw, matrices["area"]),
        "windshare_17p5_pop_day": aggregate_threshold_share(raw, matrices["pop"]),
        "windshare_17p5_area_day": aggregate_threshold_share(raw, matrices["area"]),
    }

    frame = pd.DataFrame({
        "date": np.repeat(dates.strftime("%Y-%m-%d").to_numpy(), n_admins),
        "year": year,
        "region_id": np.tile(admins["region_id"].to_numpy(), n_days),
    })

    # Repeat country-specific admin IDs for each day in the block
    for column in spec.id_columns:
        frame[column] = np.tile(admins[column].to_numpy(), n_days)

    # Each aggregated wind array is day x admin and follows the same row order
    for column in OUTPUT_VARIABLES:
        frame[column] = values[column].reshape(-1)

    return frame.loc[:, columns]


def write_daily_wind(variable, all_dates, local_flat, matrices, admins, spec, year, path,
                     block_days, columns, row_min, row_max, col_min, col_max):
    # Write the country-year in blocks so the full admin-day file does not need
    # to be held in memory
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp.csv")

    if temp.exists():
        temp.unlink()

    rows_written = 0

    try:
        for start in range(0, len(all_dates), block_days):
            stop = min(start + block_days, len(all_dates))

            # Read only ERA5-Land cells used by the normal or fallback wind weights.
            raw = read_cells_window(
                variable, start, stop,
                row_min, row_max, col_min, col_max,
                local_flat,
            )

            # These are sanity checks on the raw wind input, not scientific filters
            require(np.nanmin(raw) >= 0, "Negative wind speed found")
            require(np.nanmax(raw) < 120, "Implausibly high wind speed found")

            frame = block_frame(
                year,
                all_dates[start:stop],
                admins,
                raw,
                matrices,
                spec,
                columns,
            )

            # Check each block before appending it to the daily output
            require(frame.columns.tolist() == columns, "Unexpected output columns")
            require(not frame[["date", "region_id"]].duplicated().any(), "Duplicate daily wind keys")
            require(frame[OUTPUT_VARIABLES].notna().any().all(), "A wind output variable is entirely missing")
            require(
                not (frame[["windmax_pop_day", "windmax_area_day"]] < 0).any().any(),
                "Negative daily wind value",
            )
            require(
                (
                    frame[["windshare_17p5_pop_day", "windshare_17p5_area_day"]]
                    .dropna()
                    .le(1)
                    .all()
                    .all()
                ),
                "Daily high-wind share is above one",
            )

            # Append the current block to the temporary CSV
            # Write the header only for the first block
            frame.to_csv(
                temp,
                mode="a",
                header=not temp.exists(),
                index=False,
                float_format="%.15g",
            )

            rows_written += len(frame)
            print(f"days {start + 1}-{stop}", flush=True)

        # A complete file should have one row per admin unit for every day
        require(rows_written == len(all_dates) * len(admins), "Output row count is wrong")

        # Move the completed temporary file into its final location
        os.replace(temp, path)

    finally:
        # Remove any partial temporary file if the aggregation fails
        if temp.exists():
            temp.unlink()


# -----------------------------
# Process one country-year
# -----------------------------

def main():
    args = arguments()
    spec = country(args.country)

    # Keep requests inside the year range defined for this country
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")
    require(args.block_days > 0, "block-days must be positive")

    stem = f"era5land_{spec.code.lower()}_{spec.level}_wind_daily_{args.year}.csv"
    path = result_dir(spec) / "wind" / "daily" / stem
    columns = ["date", "year", "region_id", *spec.id_columns, *OUTPUT_VARIABLES]

    # Skip a completed country-year unless overwrite is requested
    if path.is_file() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # Wind uses the same ERA5-Land grid and admin weights as the other climate
    # variables
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)

    data = None

    try:
        # The global wind files are monthly. open_wind_file stitches the 12
        # files together so this script can still work with one daily year.
        data, wind, all_dates, flip_latitude = open_wind_file(spec, args.year, grid)
        flat_indices, matrices = apply_wind_fallback(
            spec, args.year, grid, wind, admins, flat_indices, matrices, flip_latitude
        )

        # The weights use global row/column addresses.
        # Read only the rectangle that contains this country's weighted cells.
        row_min, row_max, col_min, col_max, local_flat = cell_window(flat_indices, grid)

        write_daily_wind(
            wind,
            all_dates,
            local_flat,
            matrices,
            admins,
            spec,
            args.year,
            path,
            args.block_days,
            columns,
            row_min,
            row_max,
            col_min,
            col_max,
        )

        print(f"created daily wind: {path}", flush=True)

    finally:
        # Always close the NetCDF file, including when a check fails
        if data is not None:
            data.close()


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
