#!/usr/bin/env python3
"""
03_check_prcp_temp.py

Check ERA5-Land inputs, weights, and completed admin climate files.

This script checks whether the expected climate files exist, whether the
population and area weights are valid, and whether completed daily, monthly,
and annual admin files have the expected columns, row counts, and coverage.

Inputs:
- country settings from `settings.py`
- raw ERA5-Land file paths
- admin-grid weights and admin summaries
- daily, monthly, and annual admin climate CSVs

Outputs:
- printed JSON check results
- no data files
"""


# -----------------
# Packages
# -----------------


import argparse
import json
import sys

import numpy as np
import pandas as pd

from common import (
    CheckError,
    add_region_id,
    admin_climate_columns,
    admin_climate_paths,
    normalize_ids,
    read_admins,
    require,
)
from settings import (
    COUNTRIES,
    admin_file,
    climate_file,
    country,
    weights_file,
)


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    # Check one country, optionally for one country-year.
    parser.add_argument("--country")
    parser.add_argument("--year", type=int)
    # Check all countries listed in settings.py.
    parser.add_argument("--all-countries", action="store_true")
    return parser.parse_args()


# -----------------------------
# Source files and weights
# -----------------------------

def source_report(spec):
    # Check only whether each expected annual climate file exists
    # Shape, units, and daily dates are checked later when the aggregation opens
    # the files
    missing = {}
    for variable in ("tp_total", "tmean", "tmax"):
        missing[variable] = [
            year for year in range(spec.first_year, spec.last_year + 1)
            if not climate_file(spec, variable, year).is_file()
        ]

    return {
        "country": spec.code,
        "admin_level": spec.level,
        "shapefile_units": len(read_admins(spec)),
        "requested_years": [spec.first_year, spec.last_year],
        "missing_years": missing,
    }


def weight_report(spec):
    # Check the final weight and admin-summary files created by 01_make_weights.py
    require(weights_file(spec).is_file(), f"Missing weights: {weights_file(spec)}")
    require(admin_file(spec).is_file(), f"Missing admin summary: {admin_file(spec)}")

    # Read country-specific admin IDs as strings so leading zeros are preserved.
    # These columns record population-weight fallback from the weights file, so keep them as text.
    dtype = {column: "string" for column in spec.id_columns}
    dtype.update({"popwt_fallback": "string", "areawt_fallback": "string"})
    weights = pd.read_csv(weights_file(spec), dtype=dtype)
    admins = pd.read_csv(admin_file(spec), dtype=dtype)

    # Some admin summary files already have region_id, older ones do not.
    # Rebuild region_id from the source ID columns so the check uses one format.
    if "region_id" not in weights:
        weights = add_region_id(weights, spec)
    else:
        weights = normalize_ids(weights, spec)

    if "region_id" not in admins:
        admins = add_region_id(admins, spec)
    else:
        admins = normalize_ids(admins, spec)

    # Each admin unit should appear once in the summary and each admin-grid cell
    # should appear once in the weight file
    require(not admins.region_id.duplicated().any(), "Duplicate admin IDs")
    require(
        not weights.duplicated(["region_id", "grid_row", "grid_column"]).any(),
        "Duplicate admin-grid rows",
    )

    # Check population and area weights separately
    # Population weights may use the area-weight fallback from 01_make_weights.py,
    # but both final weight sets should still sum to one for covered admin units
    sums = weights.groupby("region_id")[["popwt", "areawt"]].sum()
    require((sums >= 0).all().all(), "Negative weights")

    # Covered admin units have positive area weights.
    positive = sums.areawt > 0
    require(np.allclose(sums.loc[positive, "areawt"], 1), "Area weights do not sum to one")
    require(np.allclose(sums.loc[positive, "popwt"], 1), "Population weights do not sum to one")

    return {
        "admin_rows": len(admins),
        "weight_rows": len(weights),
        "covered_admins": int(positive.sum()),
        "uncovered_admins": int(len(admins) - positive.sum()),
        "max_population_sum_error": float((sums.loc[positive, "popwt"] - 1).abs().max()),
        "max_area_sum_error": float((sums.loc[positive, "areawt"] - 1).abs().max()),
    }


# -----------------------------
# Completed climate outputs
# -----------------------------

def result_report(spec, year):
    # Daily, monthly, and annual files should all exist for a completed
    # country-year
    paths = admin_climate_paths(spec, year)
    for path in paths.values():
        require(path.is_file(), f"Missing result: {path}")

    ids = ["region_id", *spec.id_columns]

    # These are the columns written by 02_aggregate_prcp_temp.py for each output.
    expected = {
        "daily": ["date", *ids, *admin_climate_columns()],
        "monthly": ["month", *ids, *admin_climate_columns()],
        "annual": ["year", *ids, *admin_climate_columns()],
    }

    report = {}

    # Number of admin units determines the expected row count at each frequency
    n_admins = len(pd.read_csv(admin_file(spec), usecols=[spec.id_columns[0]]))
    days = 366 if pd.Timestamp(year, 12, 31).dayofyear == 366 else 365
    expected_rows = {
        "daily": days * n_admins,
        "monthly": 12 * n_admins,
        "annual": n_admins,
    }

    for frequency, path in paths.items():
        # Check both column names and column order
        # The mortality panel code expects these outputs to stay in a fixed form
        header = pd.read_csv(path, nrows=0).columns.tolist()
        require(header == expected[frequency], f"Unexpected columns in {path}")

        # Count rows without loading the full daily file into memory
        rows = sum(1 for _ in open(path, encoding="utf-8")) - 1
        require(rows == expected_rows[frequency], f"Unexpected row count in {path}")

        report[frequency] = {
            "path": str(path),
            "rows": rows,
        }

    # Every annual climate variable should have at least one non-missing admin
    # value
    annual = pd.read_csv(paths["annual"])
    require(
        (
            annual.filter(regex=r"^(prcp|tmean|tmax)_")
            .notna()
            .sum()
            > 0
        ).all(),
        "An annual climate column is entirely missing",
    )

    coverage = {}

    # Powers 1 through 5 for the same variable and weighting use the same daily
    # climate cells, so they should have the same missing admin units
    for variable in ("prcp", "tmean", "tmax"):
        for weighting in ("pop", "area"):
            columns = [
                f"{variable}_{weighting}_p{power}" for power in range(1, 6)
            ]
            valid = annual[columns].notna()

            # If p1 is missing for an admin unit, p2-p5 should be missing too
            # Different patterns would indicate a problem in the aggregation
            require(
                valid.eq(valid.iloc[:, 0], axis=0).all().all(),
                f"{variable} powers have different missing admin units",
            )

            p1_missing = valid.iloc[:, 0].eq(False)
            missing = annual.loc[p1_missing, "region_id"].tolist()
            coverage[f"{variable}_{weighting}"] = {
                "valid_admins": int(valid.iloc[:, 0].sum()),
                "missing_admins": len(missing),
                "missing_region_ids": missing,
            }

    report["effective_climate_coverage"] = coverage
    return report


# -----------------------------
# Main
# -----------------------------

def main():
    args = arguments()

    if args.all_countries:
        # List missing climate inputs for every country before running the
        # heavier aggregation jobs
        print(json.dumps([source_report(spec) for spec in COUNTRIES.values()], indent=2))
        return

    require(args.country is not None, "--country is required unless --all-countries is used")
    spec = country(args.country)

    # Source-file checks can run before weights or country-year results exist
    report = {"sources": source_report(spec)}

    # Add weight checks once the final weight file has been created
    if weights_file(spec).is_file():
        report["weights"] = weight_report(spec)

    # Add daily/monthly/annual result checks when a year is requested
    if args.year is not None:
        report["results"] = result_report(spec, args.year)

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Print failed checks clearly and make Slurm mark the job as failed.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
