#!/usr/bin/env python3
"""
05_aggregate_annual_wind.py

Aggregate annual ERA5-Land wind exposure for one country-year.

This script reads the monthly global ERA5-Land `wind_max` files for one year
and aggregates daily wind to admin units using the weights created by
`01_make_weights.py`.

Outputs:
- population- and area-weighted annual maximum wind
- population- and area-weighted high-wind days above 17.5 m/s
- wind-only fallback audit CSV when fallback cells are used

ERA5-Land wind captures high wind from any weather system. It can include
tropical cyclones, but it is not limited to them.

The annual maximum is calculated in this order:

    daily cell wind -> cell annual max -> admin weighted mean

The annual maximum is taken at the grid-cell level first, then averaged to the
admin unit. This is intentional: it keeps localized wind extremes before spatial
averaging, instead of averaging wind to the admin level first and then taking an
annual maximum.

For the threshold measure, each day's value is the weighted share of the admin
unit with wind above 17.5 m/s, or about 63 km/h. These daily shares are summed
over the year. For example, if half of an admin unit is above the threshold for
two days, the annual value is one full admin-day above the threshold.

Some small islands have normal climate weights but no finite `wind_max` values
in the ERA5-Land cells used by those weights. For wind only, affected weights
can be moved to the nearest finite wind cell within 1.6 degrees. Precipitation
and temperature weights are not affected by this and unchanged. 

Inputs:
- country-month-year ERA5-Land `wind_max` NetCDF files with daily values
- admin-grid weights from `01_make_weights.py`
"""

# -----------------
# Packages
# -----------------

import argparse
import sys

import numpy as np
import pandas as pd

from common import (
    CheckError,
    WIND_OUTPUT_COLUMNS,
    admin_wind_columns,
    admin_wind_path,
    atomic_csv,
    cell_window,
    load_weights,
    read_cells_window,
    read_grid,
    require,
)
from settings import climate_file, country
from wind_common import (
    HIGH_WIND_THRESHOLD,
    aggregate_with_finite_cells,
    apply_wind_fallback,
    open_wind_file,
)


# -----------------------------
# Wind Choice
# -----------------------------

# HIGH_WIND_THRESHOLD comes from wind_common.py so the daily and annual wind
# scripts use the same 17.5 m/s cutoff.


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
# Build annual wind measures
# -----------------------------

def annual_wind_measures(variable, all_dates, local_flat, matrices, block_days,
                         row_min, row_max, col_min, col_max):
    """Read wind in blocks and build the four annual wind variables."""

    n_cells = len(local_flat)
    n_admins = matrices["pop"].shape[0]

    # Highest daily wind observed in each ERA5-Land cell over the year
    cell_annual_max = np.full(n_cells, np.nan)

    # Sum daily weighted shares above 17.5 m/s
    # Separate counters track whether each admin has any valid daily values
    winddays = {
        "pop": np.zeros(n_admins),
        "area": np.zeros(n_admins),
    }
    winddays_valid = {
        "pop": np.zeros(n_admins, dtype="int16"),
        "area": np.zeros(n_admins, dtype="int16"),
    }

    for start in range(0, len(all_dates), block_days):
        stop = min(start + block_days, len(all_dates))

        # Read only the global rows and columns used by this country's weights.
        raw = read_cells_window(
            variable, start, stop,
            row_min, row_max, col_min, col_max,
            local_flat,
        )

        # Sanity checks
        require(np.nanmin(raw) >= 0, "Negative wind speed found")
        require(np.nanmax(raw) < 120, "Implausibly high wind speed found")

        # Keep each grid cell's highest daily wind over the year
        # Spatial aggregation happens only after the cell-level annual maximum
        finite_cells = np.isfinite(raw)
        block_max = np.max(np.where(finite_cells, raw, -np.inf), axis=0)
        block_max[~finite_cells.any(axis=0)] = np.nan
        cell_annual_max = np.fmax(cell_annual_max, block_max)

        # Convert each grid cell/day to an indicator for wind above 17.5 m/s
        high_wind = np.where(np.isfinite(raw), raw > HIGH_WIND_THRESHOLD, np.nan)
        finite = np.isfinite(high_wind)

        for weighting, matrix in matrices.items():
            # Daily value = weighted share of the admin unit above the threshold
            # Example: 0.25 means 25% of the weighted admin area/population is
            # above 17.5 m/s on that day
            denominator = np.asarray(matrix @ finite.T).T
            numerator = np.asarray(matrix @ np.where(finite, high_wind, 0).T).T
            daily_share = np.full(numerator.shape, np.nan)
            np.divide(numerator, denominator, out=daily_share, where=denominator > 0)

            # Summing daily shares gives equivalent full-admin high-wind days
            winddays[weighting] += np.nansum(daily_share, axis=0)
            winddays_valid[weighting] += np.isfinite(daily_share).sum(axis=0)

        print(f"days {start + 1}-{stop}", flush=True)

    # Annual max uses cell annual maximum first, then admin weighted average
    # Threshold days use the sum of daily weighted high-wind shares
    return {
        "windmax_pop_annual": aggregate_with_finite_cells(cell_annual_max, matrices["pop"]),
        "windmax_area_annual": aggregate_with_finite_cells(cell_annual_max, matrices["area"]),
        "winddays_17p5_pop_annual": np.where(winddays_valid["pop"] > 0, winddays["pop"], np.nan),
        "winddays_17p5_area_annual": np.where(winddays_valid["area"] > 0, winddays["area"], np.nan),
    }


# -----------------------------
# Build and check output
# -----------------------------

def build_output_frame(year, admins, measures, spec):
    """Combine admin identifiers and annual wind measures."""

    frame = pd.DataFrame({
        "year": year,
        "region_id": admins["region_id"],
    })

    for column in spec.id_columns:
        frame[column] = admins[column]

    for column in WIND_OUTPUT_COLUMNS:
        frame[column] = measures[column]

    return frame


def check_output(frame, spec):
    """Check the annual wind output before writing."""

    require(frame.columns.tolist() == admin_wind_columns(spec), "Unexpected output columns")
    require(not frame["region_id"].duplicated().any(), "Duplicate region IDs in output")

    # Every wind variable should contain at least one valid admin value
    require(
        frame[WIND_OUTPUT_COLUMNS].notna().any().all(),
        "A wind output variable is entirely missing",
    )

    # Annual maximum wind and high-wind-day measures cannot be negative
    require(
        not (frame[["windmax_pop_annual", "windmax_area_annual"]] < 0).any().any(),
        "Negative wind maximum",
    )
    require(
        not (frame[["winddays_17p5_pop_annual", "winddays_17p5_area_annual"]] < 0).any().any(),
        "Negative high-wind days",
    )


# -----------------------------
# Process one country-year
# -----------------------------

def main():
    args = arguments()
    spec = country(args.country)

    # Keep requests inside the year range defined for this country
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")
    require(args.block_days > 0, "block-days must be positive")

    path = admin_wind_path(spec, args.year)

    # Skip an existing country-year unless overwrite is requested
    if path.is_file() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # The normal admin weights were built on the precipitation grid
    # Require the wind file to use that same ERA5-Land grid before applying them
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)

    data = None

    try:
        # The global wind files are monthly. open_wind_file stitches the 12
        # files together so this script can still work with one daily year.
        data, wind, all_dates, flip_latitude = open_wind_file(spec, args.year, grid)

        # Apply any wind-only cell fallback before calculating annual measures
        # Replacement cells therefore enter both the annual maximum and the
        # high-wind-day calculation
        flat_indices, matrices = apply_wind_fallback(
            spec, args.year, grid, wind, admins, flat_indices, matrices, flip_latitude
        )

        # The weights use global row/column addresses.
        # Read only the rectangle that contains this country's weighted cells.
        row_min, row_max, col_min, col_max, local_flat = cell_window(flat_indices, grid)

        # Calculate annual maximum wind and equivalent high-wind days
        measures = annual_wind_measures(
            wind, all_dates, local_flat, matrices, args.block_days,
            row_min, row_max, col_min, col_max,
        )

        output = build_output_frame(args.year, admins, measures, spec)
        check_output(output, spec)
        atomic_csv(output, path)

        # Final file should contain exactly one row per admin unit
        require(
            sum(1 for _ in open(path, encoding="utf-8")) - 1 == len(admins),
            "Output row count is wrong",
        )

        print(f"created wind exposure: {path}")

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
