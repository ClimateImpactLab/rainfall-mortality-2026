#!/usr/bin/env python3
"""
step_02_apply_fallback.py

Move weights for reviewed admin units when all of their ERA5-Land cells are
missing precipitation and temperature.

This is for small coastal or island units whose weighted cells are masked by
the ERA5-Land land mask.

There are two run modes:
- `--check` writes a detailed check CSV and does not change weights.
- `--apply` writes the same report and moves weights to nearby valid land
  cells.

Inputs:
- country weight table built by `01_make_weights.py`
- fallback ID CSV with a `region_id` column
- first day of `tp_total`, `tmean`, and `tmax` for the selected year

Outputs:
- detailed check CSV showing which cells were checked, moved, or left alone
- updated weight table, only when run with `--apply`
- backup of the original weight table, only when weights are updated
"""


# -----------------
# Packages
# -----------------

import argparse
from pathlib import Path
import shutil

from netCDF4 import Dataset
import numpy as np
import pandas as pd
from scipy.spatial import cKDTree

from common import atomic_csv, ensure_region_id, read_grid, require
from settings import climate_file, country, weights_file


WEIGHTS = (
    ("popwt", "popwt_fallback", "population"),
    ("areawt", "areawt_fallback", "area"),
)

# A row is one admin unit x ERA5-Land cell. These columns identify that row.
KEYS = ["region_id", "grid_row", "grid_column"]

# These notes mark where weight was removed and where it was added.
FALLBACK_SOURCE = "moved_to_nearest_valid_cell_source"
FALLBACK_TARGET = "moved_to_nearest_valid_cell_target"


# -----------------------------
# Arguments
# -----------------------------

def arguments():
    parser = argparse.ArgumentParser(description=__doc__)

    # Country, year, and reviewed admin units to check or move.
    parser.add_argument("--country", required=True)
    parser.add_argument("--year", type=int)
    parser.add_argument("--region-id-file", type=Path, required=True)

    # Reject a move if the replacement cell is farther than this.
    parser.add_argument("--max-distance-degrees", type=float, default=0.5)

    # Exact CSV path for the detailed check report.
    parser.add_argument("--check-report", type=Path, required=True)

    # Check writes only the report. Apply writes the report and updates weights.
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    require(args.check != args.apply, "Choose exactly one run type: --check or --apply")
    require(args.max_distance_degrees >= 0, "--max-distance-degrees must be nonnegative")
    return args


def read_fallback_ids(path):
    # This is the reviewed list from step_01_make_fallback_ids.py.
    # Only these admin units are allowed to be checked or moved here.
    ids = pd.read_csv(path, dtype={"region_id": "string"})
    require("region_id" in ids.columns, f"Missing region_id column: {path}")

    region_ids = ids["region_id"].astype("string").str.strip()
    require(region_ids.notna().all() and (region_ids != "").all(), f"Bad region_id in {path}")
    require(not region_ids.duplicated().any(), f"Duplicate region_id in {path}")
    return region_ids.tolist()


# -----------------------------
# Valid climate cells
# -----------------------------

def valid_climate_cells(spec, year, grid):
    masks = []
    paths = []

    # A replacement cell must have precipitation, mean temp, and max temp.
    for variable in ("tp_total", "tmean", "tmax"):
        path = climate_file(spec, variable, year)
        require(path.is_file(), f"Missing climate file: {path}")

        with Dataset(path) as data:
            require(variable in data.variables, f"Missing variable {variable} in {path}")
            values = np.asarray(data.variables[variable][0], dtype="float64")
            latitude = np.asarray(data.variables["latitude"][:], dtype="float64")
            longitude = np.asarray(data.variables["longitude"][:], dtype="float64")

        # Weights use grid_row/grid_column, so the raw file must use the same
        # ERA5-Land grid.
        require(np.allclose(longitude, grid.longitude), f"Longitudes differ from weights grid: {path}")

        # Some raw files store latitude in the opposite order.
        if np.allclose(latitude, grid.latitude):
            masks.append(np.isfinite(values))
        elif np.allclose(latitude[::-1], grid.latitude):
            masks.append(np.isfinite(values[::-1, :]))
        else:
            require(False, f"Latitudes differ from weights grid: {path}")

        paths.append(path)

    require(all(mask.shape == masks[0].shape for mask in masks), "Climate variables use different grid shapes")
    return np.logical_and.reduce(masks), paths


# -----------------------------
# Weight edits
# -----------------------------

def move_weight(weights, region_id, replacement, weight_column, note_column, grid):
    # Find or add the target cell, then move the full source weight there.
    amount = float(weights.at[replacement["source_index"], weight_column])
    target_row = replacement["target_row"]
    target_column = replacement["target_column"]

    target = (
        weights["region_id"].eq(region_id)
        & weights["grid_row"].eq(target_row)
        & weights["grid_column"].eq(target_column)
    )

    if not target.any():
        new_row = weights.loc[weights["region_id"].eq(region_id)].iloc[0].to_dict()
        for column in ("population", "land_area_km2", "popwt", "areawt"):
            new_row[column] = 0.0
        new_row["grid_row"] = target_row
        new_row["grid_column"] = target_column
        new_row["latitude"] = float(grid.latitude[target_row])
        new_row["longitude"] = float(grid.longitude[target_column])
        new_row["popwt_fallback"] = ""
        new_row["areawt_fallback"] = ""
        weights = pd.concat([weights, pd.DataFrame([new_row])], ignore_index=True)
        target = (
            weights["region_id"].eq(region_id)
            & weights["grid_row"].eq(target_row)
            & weights["grid_column"].eq(target_column)
        )

    target_index = weights.index[target][0]
    source_index = replacement["source_index"]

    # Keep both rows, but move the selected weight from source to target.
    weights.at[source_index, weight_column] = 0.0
    weights.at[source_index, note_column] = FALLBACK_SOURCE
    weights.at[target_index, weight_column] = float(weights.at[target_index, weight_column]) + amount
    weights.at[target_index, note_column] = FALLBACK_TARGET
    return weights


def check_changed_weights(original, edited, fallback_ids, valid_mask):
    # No duplicate rows or negative weights after editing.
    require(not edited.duplicated(KEYS).any(), "Duplicate admin-cell rows after fallback")
    require((edited[["popwt", "areawt"]] >= -1e-15).all().all(), "Negative weights after fallback")

    # Admin units not listed for fallback must not change.
    original_other = original.loc[~original["region_id"].isin(fallback_ids)].sort_values(KEYS).reset_index(drop=True)
    edited_other = edited.loc[~edited["region_id"].isin(fallback_ids)].sort_values(KEYS).reset_index(drop=True)
    pd.testing.assert_frame_equal(original_other, edited_other, check_dtype=False)

    # Population and area weights should still sum to one.
    changed = edited.loc[edited["region_id"].isin(fallback_ids)]
    for region_id, rows in changed.groupby("region_id"):
        for weight_column, _, _ in WEIGHTS:
            total = float(rows[weight_column].sum())
            if total > 0:
                require(np.isclose(total, 1, atol=1e-10), f"{region_id} {weight_column} does not sum to one")

    # Target cells must have valid precipitation and temperature.
    targets = edited.loc[edited[["popwt_fallback", "areawt_fallback"]].eq(FALLBACK_TARGET).any(axis=1)]
    for row in targets.itertuples(index=False):
        require(bool(valid_mask[int(row.grid_row), int(row.grid_column)]), f"Fallback target is missing climate: {row.region_id}")


# -----------------------------
# Main
# -----------------------------

def main():
    args = arguments()
    spec = country(args.country)
    year = args.year if args.year is not None else spec.grid_year

    path = weights_file(spec)
    require(path.is_file(), f"Missing weights file: {path}")

    # Only these admin units can be changed.
    fallback_ids = read_fallback_ids(args.region_id_file)

    # Mark ERA5-Land cells that have all needed climate variables.
    grid = read_grid(climate_file(spec, "tp_total", spec.grid_year))
    valid_mask, climate_paths = valid_climate_cells(spec, year, grid)
    require(valid_mask.shape == (len(grid.latitude), len(grid.longitude)), "Climate files do not match weights grid")

    # Set up nearest-cell match among valid ERA5-Land land cells.
    valid_rows, valid_columns = np.where(valid_mask)
    require(len(valid_rows) > 0, "No valid climate cells found")
    valid_points = np.column_stack([grid.latitude[valid_rows], grid.longitude[valid_columns]])
    nearest_valid_cell = cKDTree(valid_points)

    # Keep admin IDs as text so leading zeros are not lost.
    # The weights file has one row per admin unit x ERA5-Land cell.
    dtype = {column: "string" for column in spec.id_columns}
    dtype["region_id"] = "string"
    weights = pd.read_csv(path, dtype=dtype, low_memory=False)
    weights = ensure_region_id(weights, spec)
    require(not weights.duplicated(KEYS).any(), "Input weight file has duplicate admin-cell rows")

    missing = sorted(set(fallback_ids) - set(weights["region_id"]))
    require(not missing, f"Fallback IDs missing from weights: {', '.join(missing)}")

    # These columns record source and target cells after fallback.
    for column in ("popwt_fallback", "areawt_fallback"):
        if column not in weights.columns:
            weights[column] = ""
        weights[column] = weights[column].fillna("").astype(str)

    original = weights.copy()
    edited = weights.copy()
    check_rows = []
    moved_pairs = 0
    rejected_pairs = 0
    climate_paths_text = ";".join(map(str, climate_paths))

    # Empty cell fields keep the check columns present even when nothing moves.
    empty_cell = {
        "source_grid_row": np.nan,
        "source_grid_column": np.nan,
        "source_longitude": np.nan,
        "source_latitude": np.nan,
        "source_weight": np.nan,
        "replacement_grid_row": np.nan,
        "replacement_grid_column": np.nan,
        "replacement_longitude": np.nan,
        "replacement_latitude": np.nan,
        "distance_degrees": np.nan,
    }

    for region_id in fallback_ids:
        # Use the original rows when deciding whether fallback is needed.
        region_rows = original.loc[original["region_id"].eq(region_id)]

        # Check population and area weights separately.
        for weight_column, note_column, weight_type in WEIGHTS:
            positive = region_rows.loc[region_rows[weight_column] > 0].copy()
            total = float(positive[weight_column].sum())

            # Common check fields for this admin-weight pair.
            check_base = {
                "country": spec.code,
                "region_id": region_id,
                "weight_type": weight_type,
                "weight_column": weight_column,
                "original_positive_weight_cell_count": int(len(positive)),
                "original_total_weight": total,
                "maximum_allowed_distance_degrees": args.max_distance_degrees,
                "source_weight_file_path": str(path),
                "climate_file_used_to_define_valid_cells": climate_paths_text,
            }

            if positive.empty:
                # No positive weight means there is nothing to move.
                check_rows.append({
                    **check_base, **empty_cell,
                    "action": "no_change",
                    "status": "no_positive_weight",
                })
                continue

            require(np.isclose(total, 1, atol=1e-10), f"{region_id} {weight_column} does not sum to one before fallback")

            # Source cells must fit inside the raw climate grid.
            rows = positive["grid_row"].to_numpy(dtype="int64")
            columns = positive["grid_column"].to_numpy(dtype="int64")
            in_grid = (rows >= 0) & (rows < valid_mask.shape[0]) & (columns >= 0) & (columns < valid_mask.shape[1])
            require(in_grid.all(), f"{region_id} {weight_column} references a cell outside the climate grid")

            # Fallback is only needed if every weighted cell is missing climate.
            if valid_mask[rows, columns].any():
                check_rows.append({
                    **check_base, **empty_cell,
                    "action": "no_change",
                    "status": "fallback_not_needed",
                })
                continue

            replacements = []

            # Find the nearest valid land cell for each source cell.
            for source_index, row in positive.iterrows():
                distance, target_index = nearest_valid_cell.query([[row.latitude, row.longitude]], k=1)
                target_number = int(target_index[0])
                replacements.append({
                    "source_index": source_index,
                    "source_row": int(row.grid_row),
                    "source_column": int(row.grid_column),
                    "source_weight": float(row[weight_column]),
                    "target_row": int(valid_rows[target_number]),
                    "target_column": int(valid_columns[target_number]),
                    "distance": float(distance[0]),
                })

            # Reject the whole admin-weight pair if one replacement is too far.
            too_far = any(item["distance"] > args.max_distance_degrees + 1e-12 for item in replacements)

            if too_far:
                rejected_pairs += 1
                for item in replacements:
                    check_rows.append({
                        **check_base,
                        "source_grid_row": item["source_row"],
                        "source_grid_column": item["source_column"],
                        "source_longitude": float(grid.longitude[item["source_column"]]),
                        "source_latitude": float(grid.latitude[item["source_row"]]),
                        "source_weight": item["source_weight"],
                        "replacement_grid_row": item["target_row"],
                        "replacement_grid_column": item["target_column"],
                        "replacement_longitude": float(grid.longitude[item["target_column"]]),
                        "replacement_latitude": float(grid.latitude[item["target_row"]]),
                        "distance_degrees": item["distance"],
                        "action": "no_change",
                        "status": "distance_exceeds_limit",
                    })
                continue

            moved_pairs += 1
            action = "would_move_weight" if args.check else "moved_weight"
            status = "checked" if args.check else "applied"

            for item in replacements:
                # Check mode records the move. Apply mode also edits weights.
                check_rows.append({
                    **check_base,
                    "source_grid_row": item["source_row"],
                    "source_grid_column": item["source_column"],
                    "source_longitude": float(grid.longitude[item["source_column"]]),
                    "source_latitude": float(grid.latitude[item["source_row"]]),
                    "source_weight": item["source_weight"],
                    "replacement_grid_row": item["target_row"],
                    "replacement_grid_column": item["target_column"],
                    "replacement_longitude": float(grid.longitude[item["target_column"]]),
                    "replacement_latitude": float(grid.latitude[item["target_row"]]),
                    "distance_degrees": item["distance"],
                    "action": action,
                    "status": status,
                })

                if args.apply:
                    edited = move_weight(edited, region_id, item, weight_column, note_column, grid)

    # Check runs write only the report. Apply runs also write the edited weights.
    check_changed_weights(original, edited, fallback_ids, valid_mask)
    atomic_csv(pd.DataFrame(check_rows), args.check_report)

    print(f"country={spec.code}")
    print(f"year={year}")
    print(f"fallback_units={len(fallback_ids)}")
    print(f"admin_weight_pairs_to_move={moved_pairs}")
    print(f"admin_weight_pairs_too_far={rejected_pairs}")

    if args.apply and moved_pairs > 0:
        # Keep the original weights once before writing the edited version.
        backup = path.with_suffix(".before_valid_cell_fallback.csv")
        if not backup.exists():
            shutil.copy2(path, backup)
            print(f"backup_created={backup}")
        else:
            print(f"backup_kept={backup}")

        atomic_csv(edited, path)
        print(f"updated={path}")
    elif args.check:
        print("weights_unchanged=true")
    else:
        print("weights_unchanged=true no_admin_weight_pairs_to_move=true")


if __name__ == "__main__":
    main()
