#!/usr/bin/env python3
"""
04_combine_prcp_temp.py

Combine annual ERA5-Land climate files across countries.

This script reads the country-year annual CSVs and stacks them into one climate
table for later panel merges. It does not change the original country-year
files.

Inputs:
- country-year annual ERA5-Land climate CSVs
- country admin summary files used for row-count checks

Outputs:
- `era5land_admin_annual.csv`
- `era5land_admin_annual.dta`
- `era5land_admin_annual_coverage.csv`

The combined files contain one row per climate country, region ID, and year.
All population- and area-weighted powers for precipitation, mean temperature,
and maximum temperature are retained.
"""


# -------------------------
# Packages and output paths
# -------------------------


import os
from pathlib import Path

import numpy as np
import pandas as pd

from common import admin_climate_columns, admin_climate_paths, atomic_csv, require
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT, admin_file


# Write combined annual files under ERA5-LAND-GLOBAL/combined.
OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined"
OUTPUT_CSV = OUTPUT_DIR / "era5land_admin_annual.csv"
OUTPUT_DTA = OUTPUT_DIR / "era5land_admin_annual.dta"
COVERAGE_CSV = OUTPUT_DIR / "era5land_admin_annual_coverage.csv"

# Keys that should uniquely identify every row in the combined file
KEYS = ["climate_country", "region_id", "year"]

# Precipitation and temperature powers kept in the annual climate files.
POWERS = range(1, 6)


# -----------------------------
# Read country annual files
# -----------------------------

def read_country(spec):
    """Read and check all annual climate files for one country."""

    frames = []
    columns = admin_climate_columns()
    expected = ["year", "region_id", *spec.id_columns, *columns]

    # Read every requested year and check each file before combining
    for year in range(spec.first_year, spec.last_year + 1):
        path = admin_climate_paths(spec, year)["annual"]
        require(path.is_file(), f"Missing annual result: {path}")

        # Read admin IDs as strings so leading zeros are preserved
        frame = pd.read_csv(
            path,
            dtype={
                "region_id": "string",
                **{column: "string" for column in spec.id_columns},
            },
        )

        # Check the exact output structure written by 02_aggregate_prcp_temp.py
        require(
            frame.columns.tolist() == expected,
            f"Unexpected annual columns: {path}",
        )
        require(frame["year"].eq(year).all(), f"Incorrect year values: {path}")
        require(
            not frame["region_id"].duplicated().any(),
            f"Duplicate region IDs: {path}",
        )

        # Rows in the combined file are uniquely identified by climate country,
        # region ID, and year.
        # Drop country-specific shapefile IDs after the file has been checked.
        frames.append(frame[["year", "region_id", *columns]])

    # Stack all years for this country
    country = pd.concat(frames, ignore_index=True)
    country.insert(0, "climate_country", spec.code)

    # Country x region x year should be unique after stacking
    require(
        not country.duplicated(KEYS).any(),
        f"Duplicate combined keys for {spec.code}",
    )

    # Expected rows = number of admin units x number of requested years
    admin_count = len(pd.read_csv(admin_file(spec), usecols=[spec.id_columns[0]]))
    expected_rows = admin_count * (spec.last_year - spec.first_year + 1)
    require(
        len(country) == expected_rows,
        f"Unexpected combined row count for {spec.code}",
    )

    return country, admin_count


# -----------------------------
# Combine countries
# -----------------------------

def main():
    frames = []
    coverage_rows = []

    for spec in COUNTRIES.values():
        # Read and check the full annual series for one country
        frame, admin_count = read_country(spec)
        frames.append(frame)

        climate = frame[admin_climate_columns()]

        # Keep a small country-level summary for quick checks of coverage
        coverage_rows.append(
            {
                "climate_country": spec.code,
                "first_year": spec.first_year,
                "last_year": spec.last_year,
                "years": spec.last_year - spec.first_year + 1,
                "administrative_units": admin_count,
                "rows": len(frame),
                "rows_with_prcp_pop_p1": int(
                    frame["prcp_pop_p1"].notna().sum()
                ),
                "rows_with_tmean_pop_p1": int(
                    frame["tmean_pop_p1"].notna().sum()
                ),
                "rows_with_tmax_pop_p1": int(
                    frame["tmax_pop_p1"].notna().sum()
                ),
                "entirely_missing_climate_columns": int(
                    climate.notna().sum().eq(0).sum()
                ),
            }
        )

    # Stack all country annual files into one global climate table
    combined = pd.concat(frames, ignore_index=True)

    require(not combined.duplicated(KEYS).any(), "Duplicate global annual keys")
    require(
        np.isfinite(combined["year"]).all(),
        "Combined table contains an invalid year",
    )

    # Keep the final file ordered consistently by country, admin unit, and year
    combined = combined.sort_values(KEYS).reset_index(drop=True)
    coverage = pd.DataFrame(coverage_rows)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Write the combined climate file and a small country-level coverage check.
    atomic_csv(combined, OUTPUT_CSV)
    atomic_csv(coverage, COVERAGE_CSV)

    # Write a Stata copy for the old-panel merge.
    # Use a temporary file so a failed write does not leave a broken .dta.
    temporary_dta = OUTPUT_DTA.with_suffix(".tmp.dta")
    if temporary_dta.exists():
        temporary_dta.unlink()

    # Add readable labels to the main identifiers and population-weighted
    # climate variables in the Stata file
    labels = {
        "climate_country": "Climate country settings",
        "region_id": "ERA5-Land administrative region ID",
        "year": "Calendar year",
    }

    for power in POWERS:
        labels[f"prcp_pop_p{power}"] = (
            f"ERA5-Land precipitation cell power {power}, population weighted"
        )
        labels[f"tmean_pop_p{power}"] = (
            f"ERA5-Land mean temperature cell power {power}, population weighted"
        )
        labels[f"tmax_pop_p{power}"] = (
            f"ERA5-Land maximum temperature cell power {power}, population weighted"
        )

    combined.to_stata(
        temporary_dta,
        write_index=False,
        version=118,
        variable_labels=labels,
    )
    os.replace(temporary_dta, OUTPUT_DTA)

    # Print basic totals and the country-level coverage table for the Slurm log
    print(f"rows={len(combined)}")
    print(f"countries={combined['climate_country'].nunique()}")
    print(f"wrote={OUTPUT_CSV}")
    print(f"wrote={OUTPUT_DTA}")
    print(f"wrote={COVERAGE_CSV}")
    print(coverage.to_string(index=False))


if __name__ == "__main__":
    main()
