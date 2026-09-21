#!/usr/bin/env python3
"""
04_combine_state_month.py

Combine yearly ERA5-Land U.S. state-month climate files.

Stacks either yearly wind files or yearly precipitation files into one complete
state-month CSV for the requested year range.

Inputs:
- yearly state-month wind or precipitation CSVs

Outputs:
- combined state-month CSV for the requested variable and year range

This only stacks yearly climate files. It does not touch the Young-Hsiang
mortality panel.
"""

# ------------------
# Packages
# ------------------

import argparse
from pathlib import Path

import pandas as pd


# -----------------------------
# Paths
# -----------------------------

OUTPUT_DIR = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/climate_data/"
    "ERA5-LAND/USA/state_month"
)


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    # Choose the variable and continuous year range to combine.
    parser = argparse.ArgumentParser(description=__doc__)

    # Combine either yearly wind files or yearly precipitation files.
    parser.add_argument("--variable", choices=["wind", "precip"], required=True)

    # First and last calendar years to include in the combined CSV.
    parser.add_argument("--first-year", type=int, required=True)
    parser.add_argument("--last-year", type=int, required=True)

    # Replace the combined output CSV if it already exists.
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


# -----------------------------
# Combine
# -----------------------------

def main():
    args = arguments()

    # The combined file should cover one continuous year range.
    if args.first_year > args.last_year:
        raise ValueError("first-year must be <= last-year")

    # Wind and precipitation use the same file pattern except for this stem.
    if args.variable == "wind":
        stem = "era5land_usa_state_month_wind"
    elif args.variable == "precip":
        stem = "era5land_usa_state_month_precip"

    # Keep existing combined files unless the run explicitly asks to replace them.
    output_path = OUTPUT_DIR / f"{stem}_{args.first_year}_{args.last_year}.csv"
    if output_path.exists() and not args.overwrite:
        print(f"existing file kept: {output_path}")
        return

    # Require one yearly file for every year in the requested range.
    frames = []
    missing = []
    for year in range(args.first_year, args.last_year + 1):
        path = OUTPUT_DIR / f"{stem}_{year}.csv"
        if not path.is_file():
            missing.append(year)
            continue
        frames.append(pd.read_csv(path))

    if missing:
        raise FileNotFoundError(f"Missing yearly files: {missing}")

    # Stack all years and check that each state-month appears once.
    combined = pd.concat(frames, ignore_index=True)
    combined = combined.sort_values(["stfips", "year", "month"])
    if combined[["stfips", "year", "month"]].duplicated().any():
        raise RuntimeError("Duplicate state-month rows in combined output")

    # Write through a temporary file so a failed job does not leave a partial CSV.
    temporary = output_path.with_suffix(".tmp.csv")
    combined.to_csv(temporary, index=False, float_format="%.15g")
    temporary.replace(output_path)
    print(f"created {output_path}")


if __name__ == "__main__":
    main()
