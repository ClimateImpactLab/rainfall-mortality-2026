#!/usr/bin/env python3
"""
03_check_outputs.py

Check CHIRPS inputs, weights, and completed admin climate files.

Checks source files, weights, and completed daily, monthly, and annual CHIRPS
outputs. Prints a JSON summary.
"""

# -----------------------------
# Packages
# -----------------------------

import argparse
import calendar
import json
import sys

import numpy as np
import pandas as pd

from common import (
    CheckError,
    chirps_columns,
    chirps_paths,
    ensure_region_id,
    read_admins,
    require,
)
from settings import COUNTRIES, admin_file, climate_file, country, weights_file


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country")
    parser.add_argument("--year", type=int)
    parser.add_argument("--all-countries", action="store_true")
    return parser.parse_args()


# -----------------------------
# Source files and weights
# -----------------------------

def source_report(spec):
    # Missing source years are reported here.
    # Date, shape, and unit checks happen when a year is aggregated.
    missing = [
        year for year in range(spec.first_year, spec.last_year + 1)
        if not climate_file(year).is_file()
    ]

    return {
        "country": spec.code,
        "admin_level": spec.level,
        "shapefile_units": len(read_admins(spec)),
        "requested_years": [spec.first_year, spec.last_year],
        "missing_years": missing,
    }


def weight_report(spec):
    # Check the final weight and admin-summary files from 01_make_weights.py.
    require(weights_file(spec).is_file(), f"Missing weights: {weights_file(spec)}")
    require(admin_file(spec).is_file(), f"Missing admin summary: {admin_file(spec)}")

    # Read admin IDs as strings so leading zeros are preserved.
    dtype = {column: "string" for column in spec.id_columns}
    weights = pd.read_csv(weights_file(spec), dtype=dtype)
    admins = pd.read_csv(admin_file(spec), dtype=dtype)

    # Older files may not already contain region_id.
    weights = ensure_region_id(weights, spec)
    admins = ensure_region_id(admins, spec)

    # Each admin should appear once in the admin summary.
    # Each admin-grid pair should appear once in the weights.
    require(not admins.region_id.duplicated().any(), "Duplicate admin IDs")
    require(
        not weights.duplicated(["region_id", "grid_row", "grid_column"]).any(),
        "Duplicate admin-grid rows",
    )

    # Weights should be nonnegative.
    sums = weights.groupby("region_id")[["popwt", "areawt"]].sum()
    require((sums >= 0).all().all(), "Negative weights")

    # Only admins with CHIRPS coverage should have weights summing to one.
    # Uncovered admins are allowed to have zero total weight.
    positive = sums.areawt > 0

    require(np.allclose(sums.loc[positive, "areawt"], 1), "Area weights do not sum to one")
    require(np.allclose(sums.loc[positive, "popwt"], 1), "Population weights do not sum to one")

    return {
        "admin_rows": len(admins),
        "weight_rows": len(weights),
        "covered_admins": int(positive.sum()),
        "uncovered_admins": int(len(admins) - positive.sum()),
    }


# -----------------------------
# Completed climate outputs
# -----------------------------

def result_report(spec, year):
    # A completed country-year should have all three output files.
    paths = chirps_paths(spec, year)

    for path in paths.values():
        require(path.is_file(), f"Missing result: {path}")

    ids = ["region_id", *spec.id_columns]

    # Columns must exactly match 02_aggregate_daily.py, including order.
    expected = {
        "daily": ["date", *ids, *chirps_columns()],
        "monthly": ["month", *ids, *chirps_columns()],
        "annual": ["year", *ids, *chirps_columns()],
    }

    # Row counts are admins times calendar periods:
    # daily = admins x days, monthly = admins x 12, annual = admins.
    admin_rows = len(pd.read_csv(admin_file(spec), usecols=[spec.id_columns[0]]))
    days = 366 if calendar.isleap(year) else 365

    expected_rows = {
        "daily": days * admin_rows,
        "monthly": 12 * admin_rows,
        "annual": admin_rows,
    }

    report = {}

    for frequency, path in paths.items():
        # Later scripts expect these exact columns in this exact order.
        header = pd.read_csv(path, nrows=0).columns.tolist()
        require(header == expected[frequency], f"Unexpected columns in {path}")

        # Count rows directly so the large daily CSV does not need to be loaded.
        with open(path, encoding="utf-8") as handle:
            rows = sum(1 for _ in handle) - 1
        require(rows == expected_rows[frequency], f"Unexpected row count in {path}")

        report[frequency] = {
            "path": str(path),
            "rows": rows,
        }

    # This does not require every admin value to be non-missing.
    # It catches cases where a whole annual CHIRPS field is missing.
    annual = pd.read_csv(paths["annual"])

    require(
        annual[chirps_columns()].notna().sum().gt(0).all(),
        "An annual CHIRPS column is entirely missing",
    )

    return report


# -----------------------------
# Main
# -----------------------------

def main():
    args = arguments()

    if args.all_countries:
        # For all countries, only report source-file availability.
        print(json.dumps([source_report(spec) for spec in COUNTRIES.values()], indent=2))
        return

    require(args.country is not None, "--country is required unless --all-countries is used")
    spec = country(args.country)

    # For one country, start with source availability.
    # Add weights and country-year outputs when those files are present/requested.
    report = {"sources": source_report(spec)}

    if weights_file(spec).is_file():
        report["weights"] = weight_report(spec)

    if args.year is not None:
        report["results"] = result_report(spec, args.year)

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Put the failed check in the Slurm log before the job exits.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
