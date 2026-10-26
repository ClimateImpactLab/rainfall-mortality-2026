#!/usr/bin/env python3
"""
02_make_drought_flood.py

Build annual drought and flood flow measures for one country-year.

The flow is rainfall_flow (see flow_common.py).

Drought is the annual mean of the admin unit's 12 monthly flow values from
01_aggregate_monthly_flow.py. A mean is linear, so this equals taking each
cell's annual mean first and then the weighted admin mean, as long as the
same cells are finite in every month.

The annual values in 02_aggregate_prcp_temp.py are sums of daily values.
Drought here is a mean, so its columns are named flowmean_* to keep the two
apart.

Flood is the annual maximum, calculated in this order:

    monthly cell flow -> cell annual max -> admin weighted mean

This follows windmax in era5land_admin/aggregation_scripts/05_aggregate_annual_wind.py.
It keeps local flow peaks before spatial averaging. It cannot be built from the
monthly admin file, because the max of the monthly admin means is a different
(smaller or equal) number. So the flow grid is read again here.

Inputs:
- monthly admin flow CSV from 01_aggregate_monthly_flow.py
- global monthly flow file for the year (flow_common.flow_file)
- admin-grid weights from era5land_admin 01_make_weights.py

Outputs:
- annual admin flow CSV with population- and area-weighted drought (annual
  mean) and flood (annual max) measures

Dependencies: era5land_admin/settings.py, common.py, and wind_common.py, plus
flow_common.py (on PYTHONPATH through jobs/02_drought_flood.sbatch).

Run this through Slurm after 01_aggregate_monthly_flow.py for the same
country-year.
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
    atomic_csv,
    ensure_region_id,
    load_weights,
    read_grid,
    require,
)
from settings import climate_file, country
from wind_common import aggregate_with_finite_cells
from flow_common import (
    ANNUAL_COLUMNS,
    MONTHLY_COLUMNS,
    annual_flow_path,
    monthly_flow_path,
    read_flow_year,
)


# -----------------------------
# Arguments and output paths
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", required=True)
    parser.add_argument("--year", type=int, required=True)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Drought: annual mean
# -----------------------------

def annual_mean_flow(spec, year, admins):
    """Annual mean of the 12 monthly admin flow values from step 01."""

    path = monthly_flow_path(spec, year)
    require(path.is_file(), f"Missing monthly flow: {path}. Run 01_aggregate_monthly_flow.py first.")

    # Read admin IDs as strings so leading zeros are preserved
    dtype = {column: "string" for column in spec.id_columns}
    monthly = ensure_region_id(pd.read_csv(path, dtype=dtype), spec)

    month_labels = [f"{year}-{month:02d}" for month in range(1, 13)]
    require(sorted(monthly["month"].unique()) == month_labels, f"{path} does not have the 12 months of {year}")
    require(set(monthly["region_id"]) == set(admins["region_id"]), f"{path} admins differ from the weights")
    require(len(monthly) == 12 * len(admins), f"{path} row count is wrong")

    # Require all 12 monthly values before calculating the annual value
    # (same complete-year rule as 02_aggregate_prcp_temp.py)
    grouped = monthly.groupby("region_id")[MONTHLY_COLUMNS]
    mean = grouped.mean().where(grouped.count() == 12)

    # Put the admin units in the same order as the weight matrices
    mean = mean.reindex(admins["region_id"])

    return {
        "flowmean_pop_annual": mean["flow_pop"].to_numpy(),
        "flowmean_area_annual": mean["flow_area"].to_numpy(),
    }


# -----------------------------
# Flood: annual max
# -----------------------------

def annual_max_flow(year, grid, flat_indices, matrices):
    """Cell annual max of monthly flow, then admin weighted mean."""

    # month x ERA5-Land cell, only the cells used by this country's weights
    values = read_flow_year(year, grid, flat_indices)

    # Keep each grid cell's highest monthly flow over the year
    # Spatial aggregation happens only after the cell-level annual maximum
    finite = np.isfinite(values)
    cell_annual_max = np.max(np.where(finite, values, -np.inf), axis=0)
    cell_annual_max[~finite.any(axis=0)] = np.nan

    return {
        "flowmax_pop_annual": aggregate_with_finite_cells(cell_annual_max, matrices["pop"]),
        "flowmax_area_annual": aggregate_with_finite_cells(cell_annual_max, matrices["area"]),
    }


# -----------------------------
# Build and check output
# -----------------------------

def build_output_frame(year, admins, measures, spec):
    """Combine admin identifiers and annual flow measures."""

    frame = pd.DataFrame({
        "year": year,
        "region_id": admins["region_id"],
    })

    for column in spec.id_columns:
        frame[column] = admins[column]

    for column in ANNUAL_COLUMNS:
        frame[column] = measures[column]

    return frame


def check_output(frame, spec):
    """Check the annual flow output before writing."""

    expected_columns = ["year", "region_id", *spec.id_columns, *ANNUAL_COLUMNS]
    require(frame.columns.tolist() == expected_columns, "Unexpected output columns")
    require(not frame["region_id"].duplicated().any(), "Duplicate region IDs in output")

    # Every flow variable should contain at least one valid admin value.
    # There is no sign check: rainfall is a residual and can be negative.
    require(
        frame[ANNUAL_COLUMNS].notna().any().all(),
        "A flow output variable is entirely missing",
    )

    # A cell's annual mean cannot exceed its annual max, and both admin values
    # use the same weights. This fails if the finite cells change within the year.
    for weighting in ("pop", "area"):
        mean = frame[f"flowmean_{weighting}_annual"].to_numpy()
        peak = frame[f"flowmax_{weighting}_annual"].to_numpy()
        both = np.isfinite(mean) & np.isfinite(peak)
        ordered = (mean[both] <= peak[both]) | np.isclose(mean[both], peak[both])
        require(ordered.all(), f"Annual mean flow exceeds annual max flow ({weighting} weights)")


# -----------------------------
# Process one country-year
# -----------------------------

def main():
    args = arguments()
    spec = country(args.country)

    # Keep requests inside the year range defined for this country
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")

    path = annual_flow_path(spec, args.year)

    # Skip an existing country-year unless overwrite is requested
    if path.is_file() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # The admin weights were built on the precipitation grid.
    # read_flow_year requires the flow file to use that same grid.
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)

    measures = {
        **annual_mean_flow(spec, args.year, admins),
        **annual_max_flow(args.year, grid, flat_indices, matrices),
    }

    output = build_output_frame(args.year, admins, measures, spec)
    check_output(output, spec)
    atomic_csv(output, path)

    # Final file should contain exactly one row per admin unit
    require(
        sum(1 for _ in open(path, encoding="utf-8")) - 1 == len(admins),
        "Output row count is wrong",
    )

    # Summary for the log
    print(output[ANNUAL_COLUMNS].describe().to_string())
    for column in ANNUAL_COLUMNS:
        print(f"{column}: {output[column].isna().mean():.4f} share of admins missing")

    print(f"created annual flow: {path}")


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
