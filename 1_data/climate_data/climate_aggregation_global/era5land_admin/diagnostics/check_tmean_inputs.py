#!/usr/bin/env python3
"""
check_tmean_inputs.py

Check ERA5-Land `tmean` inputs before admin aggregation.

This script checks that every requested country-year has a `tmean` file with
the expected variable, units, daily length, and ERA5-Land grid. It also checks
that `tmean` dates match precipitation dates.

Inputs:
- ERA5-Land `tmean` and precipitation NetCDF files
- final admin-grid weight files

Outputs:
- printed country summary only

For countries with fallback cells, it verifies that the fallback targets are
finite for `tmean` on the pilot day. That matters because precipitation and
temperature use the same admin-grid weights.

No climate, weight, or result file is changed.
"""

import calendar
from contextlib import closing

from netCDF4 import Dataset
import numpy as np
import pandas as pd

from common import dates, ensure_region_id, read_grid, require
from settings import COUNTRIES, climate_file, weights_file


# -----------------------------
# Country Check
# -----------------------------

def check_country(spec):
    """Validate all configured tmean years and fallback target cells."""
    reference_grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    checked_years = 0
    for year in range(spec.first_year, spec.last_year + 1):
        path = climate_file(spec, "tmean", year)
        require(path.is_file(), f"Missing tmean input: {path}")
        with closing(Dataset(path)) as data:
            # tmean must match the precipitation grid used to build weights
            require("tmean" in data.variables, f"{path} has no tmean variable")
            variable = data.variables["tmean"]
            expected_days = 366 if calendar.isleap(year) else 365
            require(
                variable.shape
                == (
                    expected_days,
                    len(reference_grid.latitude),
                    len(reference_grid.longitude),
                ),
                f"Unexpected tmean shape for {path}: {variable.shape}",
            )
            require(
                getattr(variable, "units", None) == "degC",
                f"Unexpected tmean units for {path}",
            )
            require(
                np.allclose(data.variables["latitude"][:], reference_grid.latitude)
                and np.allclose(
                    data.variables["longitude"][:], reference_grid.longitude
                ),
                f"tmean grid differs from precipitation for {path}",
            )
            tmean_dates = dates(data, year)

        with closing(Dataset(climate_file(spec, "tp_total", year))) as precipitation:
            # Date alignment matters because daily aggregation combines variables by day
            require(
                dates(precipitation, year).equals(tmean_dates),
                f"tmean and precipitation dates differ for {spec.code} {year}",
            )
        checked_years += 1

    dtype = {column: "string" for column in spec.id_columns}
    weights = ensure_region_id(pd.read_csv(weights_file(spec), dtype=dtype), spec)
    fallback_columns = [
        column
        for column in ("popwt_fallback", "areawt_fallback")
        if column in weights
    ]
    fallback = (
        weights[fallback_columns]
        .fillna("")
        .eq("moved_to_nearest_valid_cell_target")
        .any(axis=1)
        if fallback_columns
        else pd.Series(False, index=weights.index)
    )

    checked_targets = 0
    if fallback.any():
        # Approved fallback target cells must also be valid for tmean
        # Otherwise precipitation fallback would not be safe for all climate variables
        grid_path = climate_file(spec, "tmean", spec.grid_year)
        with closing(Dataset(grid_path)) as data:
            first_day = np.ma.filled(data.variables["tmean"][0], np.nan)
        rows = weights.loc[fallback, "grid_row"].astype(int).to_numpy()
        columns = weights.loc[fallback, "grid_column"].astype(int).to_numpy()
        require(
            np.isfinite(first_day[rows, columns]).all(),
            f"{spec.code} has a fallback target masked for tmean",
        )
        checked_targets = int(fallback.sum())

    return {
        "country": spec.code,
        "years_checked": checked_years,
        "fallback_target_rows_checked": checked_targets,
    }


# -----------------------------
# Main
# -----------------------------

def main():
    for spec in COUNTRIES.values():
        result = check_country(spec)
        print(
            f"country={result['country']} "
            f"years_checked={result['years_checked']} "
            f"fallback_target_rows_checked={result['fallback_target_rows_checked']}"
        )


if __name__ == "__main__":
    main()
