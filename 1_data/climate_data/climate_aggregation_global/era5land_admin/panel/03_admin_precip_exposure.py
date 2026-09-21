#!/usr/bin/env python3
"""
03_admin_precip_exposure.py

Build long-run admin extreme-rain variables from daily admin precipitation.

Inputs:
- daily admin ERA5-Land CSV files with `prcp_pop_p1`

Outputs:
- annual rainfall-exposure CSV
- long-run average rainfall-exposure CSV
- coverage CSV

The annual file has one row per climate country, admin region, and year. The
long-run file averages those annual values over available daily-file years for
each climate admin region.

These files are extra panel inputs. They are separate from the old-panel
ERA5-Land merge.
"""

# ------------------
# Packages
# ------------------

import argparse

import pandas as pd

from common import admin_climate_paths, atomic_csv
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT


# -----------------------------
# Paths and choices
# -----------------------------

# Combined outputs go next to the other ERA5-Land admin climate files.
OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined"
COUNTRY_OUTPUT_DIR = OUTPUT_DIR / "admin_precip_exposure_by_country"
ANNUAL_OUTPUT = OUTPUT_DIR / "era5land_admin_precip_exposure_annual.csv"
STATIC_OUTPUT = OUTPUT_DIR / "era5land_admin_precip_exposure_static.csv"
COVERAGE_OUTPUT = OUTPUT_DIR / "era5land_admin_precip_exposure_coverage.csv"

# Count days above these fixed daily-rainfall thresholds.
THRESHOLDS_MM = (50, 100, 150, 200)

# prcp_pop_p1 is population-weighted mean daily rainfall for the admin region.
SOURCE_FIELD = "prcp_pop_p1"

# Annual output has one row per climate country, admin region, and year.
KEYS = ["climate_country", "region_id", "year"]

# These annual variables are averaged across available years in the long-run file.
EXPOSURE_VARIABLES = [
    "prcp_pop_days_gt50_ERA5LAND_admin",
    "prcp_pop_days_gt100_ERA5LAND_admin",
    "prcp_pop_days_gt150_ERA5LAND_admin",
    "prcp_pop_days_gt200_ERA5LAND_admin",
    "prcp_pop_annual_max_ERA5LAND_admin",
    "prcp_pop_p99_ERA5LAND_admin",
]


# -----------------------------
# Arguments
# -----------------------------

def parse_args():
    # Slurm can run one country at a time, the combine step stacks those files.
    parser = argparse.ArgumentParser(
        description="Build ERA5-Land admin-unit extreme precipitation exposure measures."
    )
    parser.add_argument("--country", help="Optional ISO/config country code to process.")
    parser.add_argument("--combine", action="store_true", help="Combine country outputs.")
    return parser.parse_args()


# -----------------------------
# Annual rain exposure
# -----------------------------

def read_daily_year(spec, year):
    path = admin_climate_paths(spec, year)["daily"]
    if not path.is_file():
        # Missing daily files are listed in coverage, not treated as zero-rain years.
        return None, {
            "climate_country": spec.code,
            "year": year,
            "daily_file": str(path),
            "status": "missing_file",
            "rows": 0,
            "regions": 0,
        }

    # Daily rainfall is already admin-aggregated by 02_aggregate_prcp_temp.py.
    # prcp_pop_p1 is population-weighted mean daily rainfall for the admin unit.
    id_column = spec.id_columns[-1]
    daily = pd.read_csv(
        path,
        usecols=["date", "region_id", id_column, SOURCE_FIELD],
        dtype={"region_id": "string", id_column: "string"},
    )
    daily[SOURCE_FIELD] = pd.to_numeric(daily[SOURCE_FIELD], errors="coerce")
    daily["date"] = pd.to_datetime(daily["date"], errors="coerce")

    # Count admin-days above fixed mm/day thresholds.
    # Missing rain values count as not above threshold, days_observed records
    # how many non-missing daily rain values were available.
    for threshold in THRESHOLDS_MM:
        daily[f"gt_{threshold}"] = daily[SOURCE_FIELD] > threshold

    # Annual max and p99 summarize the upper tail without imposing a threshold.
    # days_observed counts non-missing daily rainfall values.
    # Threshold counts are calendar-year counts of admin-days above each cutoff.
    annual = (
        daily.groupby(["region_id", id_column], dropna=False, sort=False)
        .agg(
            days_observed=(SOURCE_FIELD, "count"),
            prcp_pop_annual_max_ERA5LAND_admin=(SOURCE_FIELD, "max"),
            prcp_pop_p99_ERA5LAND_admin=(SOURCE_FIELD, lambda x: x.quantile(0.99)),
            **{
                f"prcp_pop_days_gt{threshold}_ERA5LAND_admin": (f"gt_{threshold}", "sum")
                for threshold in THRESHOLDS_MM
            },
        )
        .reset_index()
        .rename(columns={id_column: "source_admin_id"})
    )

    # Threshold-day counts are counts, not shares.
    for threshold in THRESHOLDS_MM:
        annual[f"prcp_pop_days_gt{threshold}_ERA5LAND_admin"] = annual[
            f"prcp_pop_days_gt{threshold}_ERA5LAND_admin"
        ].astype("int64")

    # Add country and year after the admin-year rainfall measures are built.
    annual.insert(0, "year", year)
    annual.insert(0, "climate_country", spec.code)

    # Coverage records which country-years had daily files and how many admin
    # regions were observed.
    coverage = {
        "climate_country": spec.code,
        "year": year,
        "daily_file": str(path),
        "status": "ok",
        "rows": len(daily),
        "regions": annual["region_id"].nunique(),
    }
    return annual, coverage


def read_country(spec):
    # Some country-years can be missing. Keep that visible in the coverage file.
    frames = []
    coverage = []
    for year in range(spec.first_year, spec.last_year + 1):
        annual, row = read_daily_year(spec, year)
        coverage.append(row)
        if annual is not None:
            frames.append(annual)
    return frames, coverage


# -----------------------------
# Long-run rain exposure
# -----------------------------

def summarize_static(annual):
    # One row per climate admin region.
    # Long-run exposure averages each annual measure over years with a daily file.
    # precip_exposure_years and precip_exposure_days_observed show the data behind it.
    return (
        annual.groupby(["climate_country", "region_id", "source_admin_id"], dropna=False)
        .agg(
            precip_exposure_years=("year", "nunique"),
            precip_exposure_days_observed=("days_observed", "sum"),
            **{f"{variable}_avg": (variable, "mean") for variable in EXPOSURE_VARIABLES},
        )
        .reset_index()
    )


# -----------------------------
# Write files
# -----------------------------

def country_paths(code):
    # Country files make failed Slurm array tasks easy to rerun.
    # The combined files below use the same three-table layout.
    lower = code.lower()
    return {
        "annual": COUNTRY_OUTPUT_DIR / f"era5land_admin_precip_exposure_annual_{lower}.csv",
        "static": COUNTRY_OUTPUT_DIR / f"era5land_admin_precip_exposure_static_{lower}.csv",
        "coverage": COUNTRY_OUTPUT_DIR / f"era5land_admin_precip_exposure_coverage_{lower}.csv",
    }


def write_country_outputs(spec):
    frames, coverage_rows = read_country(spec)

    # Annual rows keep the year-specific threshold counts, max, and p99.
    annual = pd.concat(frames, ignore_index=True)

    # Long-run rows average annual exposure over the available daily-file years.
    static = summarize_static(annual)

    # Coverage keeps missing daily files visible by country-year.
    coverage = pd.DataFrame(coverage_rows).sort_values(["climate_country", "year"])
    paths = country_paths(spec.code)

    # Write country outputs before the global combine step.
    atomic_csv(annual.sort_values(KEYS).reset_index(drop=True), paths["annual"])
    atomic_csv(
        static.sort_values(["climate_country", "region_id"]).reset_index(drop=True),
        paths["static"],
    )
    atomic_csv(coverage, paths["coverage"])
    print(f"{spec.code}: wrote annual, long-run, and coverage files")


def combine_country_outputs():
    # Combine all country files after the country jobs finish.
    annual_frames = []
    static_frames = []
    coverage_frames = []
    for spec in COUNTRIES.values():
        paths = country_paths(spec.code)
        # Read the three country files written above.
        annual_frames.append(pd.read_csv(paths["annual"], dtype={"region_id": "string"}))
        static_frames.append(pd.read_csv(paths["static"], dtype={"region_id": "string"}))
        coverage_frames.append(pd.read_csv(paths["coverage"]))

    # Stack countries without changing the row definitions.
    annual = pd.concat(annual_frames, ignore_index=True).sort_values(KEYS).reset_index(drop=True)
    static = (
        pd.concat(static_frames, ignore_index=True)
        .sort_values(["climate_country", "region_id"])
        .reset_index(drop=True)
    )
    coverage = (
        pd.concat(coverage_frames, ignore_index=True)
        .sort_values(["climate_country", "year"])
        .reset_index(drop=True)
    )

    # These combined files are the ones used for review and panel-build inputs.
    atomic_csv(annual, ANNUAL_OUTPUT)
    atomic_csv(static, STATIC_OUTPUT)
    atomic_csv(coverage, COVERAGE_OUTPUT)
    print("combined: wrote annual, long-run, and coverage files")


# -----------------------------
# Main
# -----------------------------

def main():
    args = parse_args()
    if args.combine:
        # Stack the country files from earlier country runs.
        combine_country_outputs()
        return
    if args.country:
        # Build one country, useful for Slurm array jobs or reruns.
        code = args.country.upper()
        write_country_outputs(COUNTRIES[code])
        return

    # Default local run: build every country, then write combined files.
    for spec in COUNTRIES.values():
        write_country_outputs(spec)
    combine_country_outputs()


if __name__ == "__main__":
    main()
