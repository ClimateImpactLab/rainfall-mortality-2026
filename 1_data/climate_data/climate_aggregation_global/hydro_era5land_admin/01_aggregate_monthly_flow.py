#!/usr/bin/env python3
"""
01_aggregate_monthly_flow.py

Aggregate one year of monthly routed flow to admin units.

This script reads the yearly global flow file written by
hydro/coarse/prepflow.py and aggregates each month's flow
(rainfall_flow) to admin units. It uses the fixed population
and land-area weights created by era5land_admin/aggregation_scripts/01_make_weights.py.

The flow is on the same ERA5-LAND-GLOBAL grid as the weights, so the weights
are reused unchanged, including any precipitation cell-fallback moves.

Inputs:
- global monthly flow file for one year (flow_common.flow_file)
- global monthly rainfall strips that prepflow.py routes (flow_common.rainfall_band_file)
- admin-grid weights from era5land_admin 01_make_weights.py

Outputs:
- monthly admin flow CSV, one row per admin unit and month, with
  - flow_pop, flow_area: weighted mean of cell flow (raw, negatives kept)
  - flow_{pop,area}_p1 to _p3: weighted mean of cell flow^1 to ^3, with
    negative cell flow set to 0 first
  - upstream_{pop,area}_p1 to _p3: the same for upstream inflow

Upstream inflow is a cell's flow minus its own rainfall: the rain that fell
upstream and flowed into the cell. prepflow.py builds each cell's flow as its
own rainfall plus the flow of the cells draining into it, so flow minus rainfall
is exactly the inflow.

The p1-p3 columns are the flow polynomial. As for prcp_poly in
02_aggregate_prcp_temp.py, the power is taken at the grid-cell level before
spatial aggregation. Summed over the 12 months they give the annual flow
polynomial (2_analysis/flows/01_measures/01_build_flow_measures.R).

Negative flow: rainfall is a residual (tp_total - SWE change), so it is
negative where the snowpack grows faster than precipitation, and
hydro/coarse/prepflow.py adds each cell's value into every cell downstream.
Negative cell flow is set to 0 before the powers are taken, otherwise a
negative month would add to the squared term like a wet month. Only the routed
cell value is set to 0: negatives already added into positive flow further
downstream stay in. flow_pop and flow_area keep the raw values, which feed the
drought/flood measures in 02_make_drought_flood.py. Negative upstream inflow
(negative rainfall upstream) is set to 0 the same way. The log reports the
share of negative cell-months and of admin-months changed by this.

Missing flow cells are handled like missing climate cells in
02_aggregate_prcp_temp.py and the wind scripts. The weights are renormalized
over the cells with finite flow, and an admin-month stays missing only when
none of its weighted cells has finite flow. Flow is NaN where the ERA5-Land
input is NaN (ocean and land-mask gaps).

Unlike the annual wind script, there is no nearest-cell fallback
(apply_wind_fallback). The flow NaN pattern is the tp_total land mask, and
the precipitation cell fallback is already built into the weights.

Dependencies: era5land_admin/settings.py, common.py, and wind_common.py, plus
flow_common.py (on PYTHONPATH through jobs/01_monthly_flow.sbatch).

Run this through Slurm for country-year jobs.
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
    load_weights,
    read_grid,
    require,
)
from settings import climate_file, country
from wind_common import aggregate_with_finite_cells
from flow_common import (
    FLOW_POWERS,
    MONTHLY_COLUMNS,
    POWER_COLUMNS,
    UPSTREAM_POWER_COLUMNS,
    monthly_flow_path,
    read_flow_year,
    read_rainfall_year,
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
# Build and check output
# -----------------------------

def monthly_frame(year, admins, flow, spec):
    """Convert month x admin arrays to one row per admin unit and month."""

    n_admins = len(admins)
    month_labels = [f"{year}-{month:02d}" for month in range(1, 13)]

    # Rows are ordered by month, then admin unit, as in the monthly output
    # of 02_aggregate_prcp_temp.py
    frame = pd.DataFrame({
        "month": np.repeat(month_labels, n_admins),
        "region_id": np.tile(admins.region_id, 12),
    })

    for column in spec.id_columns:
        frame[column] = np.tile(admins[column], 12)

    # Flatten month x admin arrays in the same order as the rows
    for column in [*MONTHLY_COLUMNS, *POWER_COLUMNS, *UPSTREAM_POWER_COLUMNS]:
        frame[column] = flow[column].reshape(-1)

    return frame


def check_output(frame, admins, spec):
    """Check the monthly flow output before writing."""

    power_columns = [*POWER_COLUMNS, *UPSTREAM_POWER_COLUMNS]
    expected_columns = ["month", "region_id", *spec.id_columns, *MONTHLY_COLUMNS, *power_columns]
    require(frame.columns.tolist() == expected_columns, "Unexpected output columns")
    require(len(frame) == 12 * len(admins), "Monthly row count is wrong")
    require(
        not frame.duplicated(["region_id", "month"]).any(),
        "Duplicate admin-month rows in output",
    )

    # Every flow variable should contain at least one valid admin-month.
    # There is no sign check on raw flow: rainfall is a residual and can be negative.
    require(
        frame[[*MONTHLY_COLUMNS, *power_columns]].notna().any().all(),
        "A flow output variable is entirely missing",
    )

    # The powers use values with negatives set to 0, so they cannot be negative
    require(
        (frame[power_columns].fillna(0) >= 0).all().all(),
        "Negative value in a flow power column",
    )

    for weighting in ("pop", "area"):
        raw = frame[f"flow_{weighting}"]

        # Same finite cells and weights as the raw flow, so the same
        # admin-months are missing (upstream is finite wherever flow is)
        for prefix in ("flow", "upstream"):
            for power in FLOW_POWERS:
                require(
                    frame[f"{prefix}_{weighting}_p{power}"].isna().equals(raw.isna()),
                    f"{prefix}_{weighting}_p{power} is missing in different admin-months than flow_{weighting}",
                )

        # Setting negative cells to 0 can only raise the weighted mean
        finite = raw.notna().to_numpy()
        p1 = frame[f"flow_{weighting}_p1"].to_numpy()[finite]
        raw = raw.to_numpy()[finite]
        require(
            ((p1 >= raw) | np.isclose(p1, raw)).all(),
            f"flow_{weighting}_p1 is below flow_{weighting}",
        )


# -----------------------------
# Process one country-year
# -----------------------------

def main():
    args = arguments()
    spec = country(args.country)

    # Keep requests inside the year range defined for this country
    require(spec.first_year <= args.year <= spec.last_year, "Year is outside the requested range")

    path = monthly_flow_path(spec, args.year)

    # Skip an existing country-year unless overwrite is requested
    if path.is_file() and not args.overwrite:
        print(f"existing file kept: {path}")
        return

    # The admin weights were built on the precipitation grid.
    # read_flow_year requires the flow file to use that same grid.
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    admins, flat_indices, matrices = load_weights(spec, grid)

    # month x ERA5-Land cell, only the cells used by this country's weights
    values = read_flow_year(args.year, grid, flat_indices)

    # Upstream inflow = flow minus the cell's own rainfall (see the docstring).
    # prepflow.py leaves flow missing where rainfall is missing, so every cell
    # with flow should have rainfall; otherwise the files do not line up.
    rainfall = read_rainfall_year(args.year, grid, flat_indices)
    require(
        not (np.isfinite(values) & ~np.isfinite(rainfall)).any(),
        "Some cells have flow but no rainfall",
    )
    upstream = values - rainfall

    # Negative cell values set to 0 for the powers only (see the docstring).
    # np.maximum keeps NaN cells as NaN.
    nonnegative = np.maximum(values, 0)
    nonnegative_upstream = np.maximum(upstream, 0)

    # Admin value for each month = weighted mean over finite cells
    flow = {}
    for weighting, matrix in matrices.items():
        flow[f"flow_{weighting}"] = np.vstack([
            aggregate_with_finite_cells(values[month], matrix)
            for month in range(12)
        ])

        # Power of each cell's value first, then the weighted mean
        for power in FLOW_POWERS:
            flow[f"flow_{weighting}_p{power}"] = np.vstack([
                aggregate_with_finite_cells(np.power(nonnegative[month], power), matrix)
                for month in range(12)
            ])
            flow[f"upstream_{weighting}_p{power}"] = np.vstack([
                aggregate_with_finite_cells(np.power(nonnegative_upstream[month], power), matrix)
                for month in range(12)
            ])

    output = monthly_frame(args.year, admins, flow, spec)
    check_output(output, admins, spec)
    atomic_csv(output, path)

    # Final file should contain exactly one row per admin unit per month
    require(
        sum(1 for _ in open(path, encoding="utf-8")) - 1 == 12 * len(admins),
        "Output row count is wrong",
    )

    # Coverage summary for the log
    for column in MONTHLY_COLUMNS:
        print(f"{column}: {output[column].isna().mean():.4f} share of admin-months missing")

    # Negative flow set to 0, for the log. Cells are the country's weighted
    # cells, each counted once. An admin-month is changed when at least one of
    # its weighted cells was negative (p1 > raw flow).
    finite = np.isfinite(values)
    negative = np.where(finite, values, 0) < 0
    print(
        f"negative cell-months set to 0: {negative.sum()} of {finite.sum()} finite "
        f"({negative.sum() / finite.sum():.4%})"
    )
    for column in MONTHLY_COLUMNS:
        observed = output[column].notna()
        changed = output.loc[observed, f"{column}_p1"] > output.loc[observed, column]
        print(f"{column}: {changed.mean():.4%} of non-missing admin-months have negative cells set to 0")

    upstream_finite = np.isfinite(upstream)
    upstream_negative = np.where(upstream_finite, upstream, 0) < 0
    print(
        f"negative upstream cell-months set to 0: {upstream_negative.sum()} of {upstream_finite.sum()} finite "
        f"({upstream_negative.sum() / upstream_finite.sum():.4%})"
    )

    print(f"created monthly flow: {path}")


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
