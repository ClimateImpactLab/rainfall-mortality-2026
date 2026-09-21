#!/usr/bin/env python3
"""
step_03_summarize_checks.py

Summarize ERA5-Land cell-fallback check files.

The detailed check file has one row per source cell checked by
`step_02_apply_fallback.py`. This script reduces those details to one row
per country, admin unit, and weight type. Use it after check or apply runs to
see which units moved, which units were too far from a valid cell, and which
units did not need fallback.

Inputs:
- one or more detailed check CSVs from `step_02_apply_fallback.py`

Output:
- summary CSV with move counts and fallback distances
"""

import argparse
from pathlib import Path

import pandas as pd

from common import atomic_csv, require


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-file", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def join_text(values):
    # Keep each status/action label once so repeated source cells do not make
    # the summary hard to read.
    values = sorted({str(value) for value in values if pd.notna(value) and str(value)})
    return ";".join(values)


# -----------------------------
# Main
# -----------------------------

def main():
    args = arguments()

    check_files = []
    for path in args.check_file:
        # Keep the source check path so summary rows can be traced back to the
        # detailed file.
        require(path.is_file(), f"Missing check file: {path}")
        check_file = pd.read_csv(path)
        check_file["check_file"] = str(path)
        check_files.append(check_file)

    detail = pd.concat(check_files, ignore_index=True)

    needed = (
        "country", "region_id", "weight_type",
        "original_positive_weight_cell_count", "original_total_weight",
        "replacement_longitude", "replacement_latitude", "distance_degrees",
        "maximum_allowed_distance_degrees", "status", "action",
        "source_weight_file_path", "climate_file_used_to_define_valid_cells",
    )
    require(set(needed).issubset(detail.columns), "Check file is missing required columns")

    rows = []
    for keys, group in detail.groupby(["country", "region_id", "weight_type"], sort=True):
        # One summary row per country, admin, and weight type.
        distances = pd.to_numeric(group["distance_degrees"], errors="coerce")

        # Keep each replacement lon/lat pair once.
        replacements = (
            group.loc[
                group["replacement_longitude"].notna()
                & group["replacement_latitude"].notna(),
                ["replacement_longitude", "replacement_latitude"],
            ]
            .drop_duplicates()
        )
        replacement_lon_lat = ";".join(
            f"{row.replacement_longitude:.6f},{row.replacement_latitude:.6f}"
            for row in replacements.itertuples(index=False)
        )

        rows.append({
            # IDs
            "country": keys[0],
            "region_id": keys[1],
            "weight_type": keys[2],

            # Original weighted cells
            "original_positive_weight_cell_count": int(group["original_positive_weight_cell_count"].max()),
            "original_total_weight": float(group["original_total_weight"].max()),

            # Replacement cells and distances
            "source_cells_checked": int(distances.notna().sum()),
            "replacement_cells": len(replacements),
            "minimum_distance_degrees": distances.min(),
            "maximum_distance_degrees": distances.max(),
            "mean_distance_degrees": distances.mean(),
            "maximum_allowed_distance_degrees": float(group["maximum_allowed_distance_degrees"].iloc[0]),
            "replacement_lon_lat": replacement_lon_lat,

            # Keep unique labels and file paths from the detailed check file.
            "statuses": join_text(group["status"]),
            "actions": join_text(group["action"]),
            "check_file": join_text(group["check_file"]),
            "source_weight_file_path": join_text(group["source_weight_file_path"]),
            "climate_files": join_text(group["climate_file_used_to_define_valid_cells"]),
        })

    summary = pd.DataFrame(rows).sort_values(["country", "region_id", "weight_type"])
    atomic_csv(summary, args.output)

    print(summary.to_string(index=False))
    print(f"wrote={args.output}")


if __name__ == "__main__":
    main()
