"""
flow_common.py

Flow code used by the hydrology admin scripts.

01_aggregate_monthly_flow.py and 02_make_drought_flood.py both read the same
routed-flow files, so the file checks live here. This follows
era5land_admin/wind_common.py, which does the same for the wind scripts.

The flow files come from hydro/coarse/prepflow.py. There is one file per year
with 12 monthly grids of upstream-accumulated rainfall_flow, era5melt_flow,
and tempmelt_flow on the ERA5-LAND-GLOBAL grid.

The flow used here is rainfall_flow only.

Inputs:
- global monthly flow files, one per year, from hydro/coarse/prepflow.py
- global monthly rainfall strips from hydro/coarse/transform.py, the input
  prepflow.py routes (used for upstream inflow)

Dependencies: era5land_admin/common.py and settings.py (on PYTHONPATH)
"""

import os
from pathlib import Path

from netCDF4 import Dataset, num2date
import numpy as np
import pandas as pd

from common import read_cells, require
from settings import result_dir


# -----------------------------
# Flow choice
# -----------------------------

FULL_FLOW_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/processed/monthly/test")

# Preview runs (jobs/*_preview.sbatch set HYDRO_FLOW_PREVIEW=1) read the flow
# from hydro/coarse/prepflow_preview.py, which covers latitude strips 0-4
# only. They write to hydro_preview/ instead of hydro/, so preview files
# cannot be mistaken for, or overwrite, the full global run.
PREVIEW = os.environ.get("HYDRO_FLOW_PREVIEW") == "1"
FLOW_ROOT = FULL_FLOW_ROOT / "preview_bands0-4" if PREVIEW else FULL_FLOW_ROOT
OUTPUT_FOLDER = "hydro_preview" if PREVIEW else "hydro"

# rainfall = tp_total - daily SWE change (mm), so it already includes snowmelt
# on melt days (hydro/coarse/transform.py). tempmelt = tmean x (SWE > 0) x
# (tmean > 0) is a degree-day index in degC-days with no melt factor, so it is
# not added: the sum would mix mm with degC-days and count melt twice in snow
# areas. Changed 2026-10-01 from rainfall_flow + tempmelt_flow; outputs written
# before then use that sum under the same file and column names.
FLOW_VARIABLE = "rainfall_flow"

MONTHLY_COLUMNS = ["flow_pop", "flow_area"]

# Flow polynomial terms, built like prcp_poly in
# era5land_admin/aggregation_scripts/02_aggregate_prcp_temp.py: each cell's
# monthly flow is raised to the power before the weighted admin mean.
# Negative cell flow is set to 0 first (01_aggregate_monthly_flow.py).
FLOW_POWERS = range(1, 4)

POWER_COLUMNS = [
    f"flow_{weighting}_p{power}"
    for weighting in ("pop", "area")
    for power in FLOW_POWERS
]

# Upstream inflow = a cell's flow minus its own rainfall, i.e. the rain that
# fell upstream and flowed in. Same powers as flow, with negative cell values
# set to 0 first (01_aggregate_monthly_flow.py).
UPSTREAM_POWER_COLUMNS = [
    f"upstream_{weighting}_p{power}"
    for weighting in ("pop", "area")
    for power in FLOW_POWERS
]

# The cell's own rainfall comes from the monthly files that prepflow.py routes.
# transform.py writes them as 8 latitude strips of the global grid.
RAINFALL_VARIABLE = "rainfall"
RAINFALL_BANDS = range(8)

ANNUAL_COLUMNS = [
    "flowmean_pop_annual",
    "flowmean_area_annual",
    "flowmax_pop_annual",
    "flowmax_area_annual",
]


# -----------------------------
# Paths
# -----------------------------

def flow_file(year):
    return FLOW_ROOT / f"global_monthly_flow_{year}.nc4"


def rainfall_band_file(band):
    # The same strips prepflow.py reads before routing
    return FULL_FLOW_ROOT / f"global_monthly_band{band}.nc4"


def flow_stem(spec):
    return f"era5land_{spec.code.lower()}_{spec.level}_flow"


def monthly_flow_path(spec, year):
    return result_dir(spec) / OUTPUT_FOLDER / "monthly" / f"{flow_stem(spec)}_monthly_{year}.csv"


def annual_flow_path(spec, year):
    return result_dir(spec) / OUTPUT_FOLDER / "annual" / f"{flow_stem(spec)}_annual_{year}.csv"


# -----------------------------
# Read one year of flow
# -----------------------------

def month_starts(data):
    # prepflow.py keeps transform.py's monthly time labels (first day of month)
    time = data.variables["valid_time"]
    decoded = num2date(
        time[:], time.units,
        calendar=getattr(time, "calendar", "proleptic_gregorian"),
        only_use_cftime_datetimes=False,
        only_use_python_datetimes=True,
    )
    return pd.DatetimeIndex([value.isoformat()[:10] for value in decoded])


def read_flow_year(year, grid, flat_indices):
    """Return month x cell flow for the ERA5-Land cells used by the weights."""

    path = flow_file(year)
    require(path.is_file(), f"Missing flow input: {path}")

    with Dataset(path) as data:
        expected = pd.date_range(f"{year}-01-01", periods=12, freq="MS")
        require(month_starts(data).equals(expected), f"Monthly dates are incomplete for {year}: {path}")

        # The weights store ERA5-Land cells by row and column number on the
        # north-to-south grid. transform.py sorts latitude south-to-north, so
        # the file must be the weights grid flipped (read_cells flips it below).
        latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
        longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
        require(
            latitude.shape == grid.latitude.shape and longitude.shape == grid.longitude.shape,
            f"Flow grid size differs from the weights grid: {path}",
        )
        require(np.allclose(longitude, grid.longitude), f"Longitudes differ from the weights grid: {path}")
        require(np.allclose(latitude[::-1], grid.latitude), f"Latitudes differ from the weights grid: {path}")

        require(FLOW_VARIABLE in data.variables, f"{path} has no {FLOW_VARIABLE}")
        variable = data.variables[FLOW_VARIABLE]

        # Cells are selected by array position, so the axis order must be fixed
        require(
            variable.dimensions == ("valid_time", "latitude", "longitude"),
            f"Unexpected dimensions for {FLOW_VARIABLE} in {path}: {variable.dimensions}",
        )
        require(
            variable.shape == (12, len(grid.latitude), len(grid.longitude)),
            f"Unexpected shape for {FLOW_VARIABLE} in {path}: {variable.shape}",
        )

        # The flow files have no units attribute, so there is no units check
        # here (unlike 02_aggregate_prcp_temp.py). Flow can also be
        # negative, because rainfall is a residual, so there is no sign check.
        # read_cells reads the full global grid for the 12 months (about
        # 0.5 GB per variable), then keeps the weighted cells.
        # read_cells_window, used by the era5land_admin scripts, reads only
        # the country's rectangle but cannot flip latitude.
        return read_cells(variable, 0, 12, flat_indices, flip_latitude=True)


def read_rainfall_year(year, grid, flat_indices):
    """Return month x cell rainfall, the input routed by prepflow.py, for the
    ERA5-Land cells used by the weights."""

    expected = pd.date_range(f"{year}-01-01", periods=12, freq="MS")
    strips = []
    latitudes = []

    for band in RAINFALL_BANDS:
        path = rainfall_band_file(band)
        require(path.is_file(), f"Missing rainfall input: {path}")

        with Dataset(path) as data:
            # Each strip holds every month of the record, so keep this year's 12
            months = month_starts(data)
            in_year = np.flatnonzero(months.year == year)
            require(
                len(in_year) == 12 and months[in_year].equals(expected) and np.all(np.diff(in_year) == 1),
                f"Monthly dates are incomplete for {year}: {path}",
            )

            longitude = np.asarray(data.variables["longitude"][:], dtype="float64")
            require(np.allclose(longitude, grid.longitude), f"Longitudes differ from the weights grid: {path}")

            require(RAINFALL_VARIABLE in data.variables, f"{path} has no {RAINFALL_VARIABLE}")
            variable = data.variables[RAINFALL_VARIABLE]

            # Cells are selected by array position, so the axis order must be fixed
            require(
                variable.dimensions == ("valid_time", "latitude", "longitude"),
                f"Unexpected dimensions for {RAINFALL_VARIABLE} in {path}: {variable.dimensions}",
            )

            values = np.ma.asarray(variable[in_year[0]:in_year[-1] + 1])
            values = np.ma.filled(values, np.nan).astype("float64", copy=False)

            # transform.py sorts each strip south-to-north. Flip it to the
            # north-to-south order of the weights grid
            strips.append(values[:, ::-1, :])
            latitudes.append(np.asarray(data.variables["latitude"][:], dtype="float64")[::-1])

    # transform.py cuts the strips from north to south, so the flipped strips
    # stacked in order should be exactly the weights grid
    latitude = np.concatenate(latitudes)
    require(
        latitude.shape == grid.latitude.shape and np.allclose(latitude, grid.latitude),
        "Rainfall strips do not stack into the weights grid",
    )

    values = np.concatenate(strips, axis=1)
    return values.reshape(12, -1)[:, flat_indices]
