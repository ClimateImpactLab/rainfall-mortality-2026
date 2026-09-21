#!/usr/bin/env python3
"""
06_combine_annual_wind.py

Combine annual ERA5-Land wind files across countries.

Each country-year wind file is written by `05_aggregate_annual_wind.py`. This
script stacks those files into one annual admin-level wind table.

Inputs:
- country-year annual wind CSVs under:

    /project/cil/gcp/estimation/rainfall-mortality/climate_data/
      ERA5-LAND-GLOBAL/<COUNTRY>/wind/

Outputs:
- `era5land_admin_wind_annual.csv`
- `era5land_admin_wind_annual_coverage.csv`

A country-year is included only when its global `wind_max` input file exists.
"""


# -----------------
# Packages
# -----------------


import sys

import pandas as pd

from common import (
    CheckError,
    WIND_OUTPUT_COLUMNS,
    admin_wind_columns,
    admin_wind_path,
    atomic_csv,
    require,
)
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT, climate_file


# -----------------------------
# Output paths
# -----------------------------

OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined"
OUTPUT_CSV = OUTPUT_DIR / "era5land_admin_wind_annual.csv"
COVERAGE_CSV = OUTPUT_DIR / "era5land_admin_wind_annual_coverage.csv"

# Country x admin unit x year should uniquely identify each row
KEYS = ["climate_country", "region_id", "year"]


# -----------------------------
# Wind years available
# -----------------------------

def available_wind_years(spec):
    # Include only years where the global wind_max input file exists.
    # A country's wind coverage can therefore be shorter than its full climate range.
    return [
        year for year in range(spec.first_year, spec.last_year + 1)
        if climate_file(spec, "wind_max", year).is_file()
    ]


# -----------------------------
# Read country wind files
# -----------------------------

def read_country(spec):
    frames = []
    coverage_rows = []
    expected = admin_wind_columns(spec)

    # Read every available wind year for this country.
    for year in available_wind_years(spec):
        path = admin_wind_path(spec, year)
        require(path.is_file(), f"Missing annual wind result: {path}")

        # Read admin IDs as strings so leading zeros are preserved
        frame = pd.read_csv(
            path,
            dtype={
                "region_id": "string",
                **{column: "string" for column in spec.id_columns},
            },
        )

        # Check the structure and basic bounds of each annual file before combining
        require(frame.columns.tolist() == expected, f"Unexpected columns: {path}")
        require(frame["year"].eq(year).all(), f"Incorrect year values: {path}")
        require(not frame["region_id"].duplicated().any(), f"Duplicate region IDs: {path}")
        require(
            not (frame[["windmax_pop_annual", "windmax_area_annual"]] < 0).any().any(),
            f"Negative wind maximum: {path}",
        )
        require(
            not (frame[["winddays_17p5_pop_annual", "winddays_17p5_area_annual"]] < 0).any().any(),
            f"Negative high-wind days: {path}",
        )
        require(
            not (
                frame[["winddays_17p5_pop_annual", "winddays_17p5_area_annual"]]
                > 366
            ).any().any(),
            f"High-wind days above 366: {path}",
        )

        # Keep one country-year row with simple coverage and extreme-value checks
        coverage_rows.append({
            "climate_country": spec.code,
            "year": year,
            "rows": len(frame),
            "rows_with_any_wind_missing": int(frame[WIND_OUTPUT_COLUMNS].isna().any(axis=1).sum()),
            "rows_with_windmax_pop": int(frame["windmax_pop_annual"].notna().sum()),
            "max_windmax_pop_annual": float(frame["windmax_pop_annual"].max(skipna=True)),
            "max_winddays_17p5_pop_annual": float(
                frame["winddays_17p5_pop_annual"].max(skipna=True)
            ),
        })

        # Country-specific admin IDs are not needed in the combined wind file
        # Keep the region ID, year, and wind variables
        frames.append(frame[["year", "region_id", *WIND_OUTPUT_COLUMNS]])

    require(frames, f"No annual wind files found for {spec.code}")

    # Stack all available wind years for this country
    country = pd.concat(frames, ignore_index=True)
    country.insert(0, "climate_country", spec.code)

    require(not country.duplicated(KEYS).any(), f"Duplicate wind keys for {spec.code}")

    return country, coverage_rows


# -----------------------------
# Combine countries
# -----------------------------

def main():
    frames = []
    coverage = []

    for spec in COUNTRIES.values():
        # Read and check all available wind years for one country
        country, rows = read_country(spec)
        frames.append(country)
        coverage.extend(rows)

    # Keep wind in a separate combined file rather than adding it directly to
    # the main ERA5-Land climate table
    # Panel scripts merge wind controls separately later.
    combined = pd.concat(frames, ignore_index=True).sort_values(KEYS).reset_index(drop=True)

    # One row per country-year with missingness and maximum-value checks
    coverage = (
        pd.DataFrame(coverage)
        .sort_values(["climate_country", "year"])
        .reset_index(drop=True)
    )

    require(not combined.duplicated(KEYS).any(), "Duplicate global wind keys")

    atomic_csv(combined, OUTPUT_CSV)
    atomic_csv(coverage, COVERAGE_CSV)

    # Print overall file size and a country-level summary for the Slurm log
    print(f"rows={len(combined)}")
    print(f"countries={combined['climate_country'].nunique()}")
    print(f"years={combined['year'].min()}-{combined['year'].max()}")
    print(f"wrote={OUTPUT_CSV}")
    print(f"wrote={COVERAGE_CSV}")
    print(
        coverage
        .groupby("climate_country")
        .agg(
            years=("year", "nunique"),
            rows=("rows", "sum"),
            rows_with_any_wind_missing=("rows_with_any_wind_missing", "sum"),
            max_windmax_pop_annual=("max_windmax_pop_annual", "max"),
            max_winddays_17p5_pop_annual=("max_winddays_17p5_pop_annual", "max"),
        )
        .reset_index()
        .to_string(index=False)
    )


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
