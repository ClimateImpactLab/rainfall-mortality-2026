#!/usr/bin/env python3
"""
01_make_weights.py

Build CHIRPS admin-to-grid-cell weights for one country.

Links each admin unit to CHIRPS grid cells and creates two sets of weights:

- population weights using LandScan 2011
- land-area weights using the GPW 2010 land-area point table

The weights are normalized within each admin unit and reused for all years.

Large countries can be split across several jobs. Each job processes a subset
of admin polygons and writes temporary files. After all parts finish, the
combine step checks that every admin unit appears once, normalizes the weights,
and writes the final files.
"""

# -----------------------------
# Packages
# -----------------------------

import argparse
import sys

import geopandas as gpd
import numpy as np
import pandas as pd
import pyarrow.dataset as pads
import rasterio
from rasterio.features import geometry_mask
from rasterio.windows import Window, from_bounds

from common import CheckError, atomic_csv, read_admins, read_grid, require
from settings import (
    GPW_LAND_AREA,
    LANDSCAN,
    admin_file,
    climate_file,
    country,
    weights_dir,
    weights_file,
)


# -----------------------------
# Arguments and paths
# -----------------------------


def arguments():
    # `--part` selects one polygon chunk.
    # `--combine` runs after all chunks have finished.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--country", required=True)
    parser.add_argument("--part", type=int)
    parser.add_argument("--parts", type=int, default=20)
    parser.add_argument("--combine", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def fragment_paths(spec, part, parts):
    # Temporary files written by each chunk before the final combine step.
    folder = weights_dir(spec) / "intermediate"
    stem = f"part_{part:03d}_of_{parts:03d}"
    return folder / f"{stem}_weights.csv", folder / f"{stem}_admins.csv"


# -----------------------------
# LandScan population weights
# -----------------------------


def clipped_window(dataset, bounds):
    # Read only the part of the global LandScan raster around one admin unit.
    # This avoids loading the full raster into memory.
    requested = from_bounds(*bounds, transform=dataset.transform)
    requested = requested.round_offsets().round_lengths()
    full = Window(0, 0, dataset.width, dataset.height)

    # Admin bounds can extend slightly outside the raster.
    # Intersect with the valid raster extent before reading.
    try:
        return requested.intersection(full)
    except rasterio.errors.WindowError:
        return None


def population_cells(dataset, geometry, grid):
    # Process one admin polygon at a time.
    # First identify the LandScan pixels inside it, then assign those pixels
    # to CHIRPS grid cells.
    window = clipped_window(dataset, geometry.bounds)
    if window is None:
        return {}, 0.0, 0.0, 0

    data = dataset.read(1, window=window, masked=True)
    transform = dataset.window_transform(window)

    # Assign a LandScan pixel when its center falls inside the polygon.
    # This matches the older mortality climate weights.
    inside_admin = geometry_mask(
        [geometry.__geo_interface__],
        out_shape=data.shape,
        transform=transform,
        invert=True,
        all_touched=False,
    )

    values = np.ma.filled(data, np.nan).astype("float64", copy=False)
    valid = inside_admin & np.isfinite(values) & (values >= 0)
    total = float(values[valid].sum())

    # Zero-population pixels count toward coverage, but not weights.
    row, column = np.nonzero(valid & (values > 0))
    if len(row) == 0:
        return {}, total, 0.0, 0

    # Use each LandScan pixel center as its location.
    # This avoids fractional raster-cell overlays.
    longitude = transform.c + (column + 0.5) * transform.a
    latitude = transform.f + (row + 0.5) * transform.e
    grid_row, grid_column, covered = grid.point_indices(latitude, longitude)
    population = values[row, column]

    # Several LandScan pixels can fall in the same CHIRPS cell.
    # Sum population to one total per admin x CHIRPS cell.
    encoded = grid_row[covered] * len(grid.longitude) + grid_column[covered]
    unique, inverse = np.unique(encoded, return_inverse=True)
    sums = np.bincount(inverse, weights=population[covered])
    cells = {
        (int(code // len(grid.longitude)), int(code % len(grid.longitude))): float(value)
        for code, value in zip(unique, sums, strict=True)
    }

    return cells, total, float(population[covered].sum()), int(covered.sum())


def population_frame(admins, grid):
    # Repeat the LandScan calculation for every admin unit in this chunk.
    # rows contains admin-grid population totals used for the weights.
    # summaries keeps one coverage record per admin unit.
    rows = []
    summaries = []

    with rasterio.open(LANDSCAN) as population:
        for number, admin in enumerate(admins.itertuples(index=False), start=1):
            print(f"population start {number}/{len(admins)} {admin.region_id}", flush=True)

            cells, total, covered, pixels = population_cells(
                population, admin.geometry, grid
            )

            for (grid_row, grid_column), value in cells.items():
                rows.append(
                    {
                        "region_id": admin.region_id,
                        "grid_row": grid_row,
                        "grid_column": grid_column,
                        "population": value,
                    }
                )

            summaries.append(
                {
                    "region_id": admin.region_id,
                    "population_total_landscan2011": total,
                    "population_covered": covered,
                    "positive_population_pixels_covered": pixels,
                }
            )

            print(f"population {number}/{len(admins)} {admin.region_id}", flush=True)

    return pd.DataFrame(rows), pd.DataFrame(summaries)


# -----------------------------
# GPW land-area weights
# -----------------------------


def land_area_frame(admins, grid):
    # GPW land area is stored here as parquet points with longitude, latitude,
    # and land_area.
    # Read only points inside the bounding box of this polygon chunk.
    print(f"land area start {len(admins)} admin units", flush=True)

    dataset = pads.dataset(GPW_LAND_AREA, format="parquet")
    xmin, ymin, xmax, ymax = admins.total_bounds
    field_lon = pads.field("longitude")
    field_lat = pads.field("latitude")
    keep = (
        (field_lon >= xmin) & (field_lon <= xmax)
        & (field_lat >= ymin) & (field_lat <= ymax)
    )

    joined = []
    admin_columns = ["region_id", "geometry"]
    matched_batches = 0
    matched_rows = 0

    # Read GPW in batches so the full point dataset is not loaded at once.
    for batch in dataset.to_batches(
        columns=["longitude", "latitude", "land_area"],
        filter=keep,
        batch_size=500_000,
    ):
        points = batch.to_pandas()

        geo = gpd.GeoDataFrame(
            points,
            geometry=gpd.points_from_xy(points.longitude, points.latitude),
            crs="EPSG:4326",
        )

        # Assign each GPW point to the admin polygon containing it.
        found = gpd.sjoin(
            geo, admins.loc[:, admin_columns],
            how="inner", predicate="within",
        ).drop(columns=["geometry", "index_right"])

        if len(found):
            joined.append(found)
            matched_batches += 1
            matched_rows += len(found)

            if matched_batches % 25 == 0:
                print(f"land area matched {matched_rows} rows so far", flush=True)

    require(joined, "No GPW land-area points matched this part")
    print(f"land area matched {matched_rows} rows", flush=True)

    points = pd.concat(joined, ignore_index=True)
    points["land_area"] = pd.to_numeric(points["land_area"], errors="raise")
    require((points["land_area"] > 0).all(), "GPW land area must be positive")

    # Assign each GPW point to the CHIRPS grid cell containing it.
    grid_row, grid_column, covered = grid.point_indices(
        points.latitude.to_numpy(), points.longitude.to_numpy()
    )
    points["grid_row"] = grid_row
    points["grid_column"] = grid_column
    points["covered"] = covered

    # Keep total GPW land area and the portion covered by the CHIRPS grid.
    summary = (
        points.groupby("region_id", as_index=False)
        .agg(
            land_area_total_gpw2010=("land_area", "sum"),
            land_area_points_total=("land_area", "size"),
        )
    )

    covered_summary = (
        points.loc[points.covered]
        .groupby("region_id", as_index=False)
        .agg(
            land_area_covered_km2=("land_area", "sum"),
            land_area_points_covered=("land_area", "size"),
        )
    )

    summary = summary.merge(covered_summary, on="region_id", how="left")

    # Several GPW points can fall in the same CHIRPS cell.
    # Sum land area to one value per admin x CHIRPS cell.
    weights = (
        points.loc[points.covered]
        .groupby(["region_id", "grid_row", "grid_column"], as_index=False)
        .land_area.sum()
        .rename(columns={"land_area": "land_area_km2"})
    )

    return weights, summary


# -----------------------------
# Build weights for one part
# -----------------------------


def make_fragment(spec, part, parts, overwrite):
    # Large countries can be divided across several Slurm jobs.
    # Each job processes one polygon chunk and writes temporary files.
    require(parts > 0 and part is not None and 0 <= part < parts, "Invalid part number")

    weight_path, admin_path = fragment_paths(spec, part, parts)

    # Avoid recomputing a finished chunk unless overwrite is requested.
    if weight_path.exists() and admin_path.exists() and not overwrite:
        print(f"existing files kept: {weight_path}")
        return

    admins = read_admins(spec)

    # Split sorted admin units into roughly equal groups.
    # Each admin unit belongs to exactly one chunk.
    indices = np.array_split(np.arange(len(admins)), parts)[part]
    require(len(indices) > 0, "This part has no admin units")
    admins = admins.iloc[indices].copy()

    # One CHIRPS file is enough to read the grid used for all years.
    grid = read_grid(climate_file(spec.pilot_year))

    # Population and land area come from separate source datasets.
    print(f"building population weights for {len(admins)} admin units", flush=True)
    pop_weights, pop_summary = population_frame(admins, grid)

    print(f"building land-area weights for {len(admins)} admin units", flush=True)
    area_weights, area_summary = land_area_frame(admins, grid)

    # Join population and land area by admin unit and CHIRPS cell.
    # Some cells contain population, land area, or both.
    weights = pop_weights.merge(
        area_weights,
        on=["region_id", "grid_row", "grid_column"],
        how="outer",
        validate="one_to_one",
    ).fillna({"population": 0.0, "land_area_km2": 0.0})

    summary_columns = [
        "region_id", *spec.id_columns, *spec.name_columns,
        "population_total_landscan2011", "population_covered",
        "positive_population_pixels_covered", "land_area_total_gpw2010",
        "land_area_points_total", "land_area_covered_km2",
        "land_area_points_covered",
    ]

    summary = (
        admins.drop(columns=["geometry", "_longitude"])
        .merge(pop_summary, on="region_id", how="left", validate="one_to_one")
        .merge(area_summary, on="region_id", how="left", validate="one_to_one")
        .loc[:, summary_columns]
    )

    numeric = [column for column in summary_columns if column not in {
        "region_id", *spec.id_columns, *spec.name_columns
    }]

    # Missing values mean no LandScan population or GPW land area was matched.
    # Keep the admin unit in the summary with zeros for later checks.
    summary[numeric] = summary[numeric].fillna(0)

    # Save temporary outputs for this chunk.
    # Final weights are created only after all chunks are combined.
    atomic_csv(weights, weight_path)
    atomic_csv(summary, admin_path)

    print(f"created {weight_path} ({len(weights)} rows)")
    print(f"created {admin_path} ({len(summary)} rows)")


# -----------------------------
# Combine chunks and create final weights
# -----------------------------


def combine_fragments(spec, parts):
    # Read every temporary chunk and check that the chunks reproduce the
    # shapefile exactly.
    weight_paths = [fragment_paths(spec, part, parts)[0] for part in range(parts)]
    admin_paths = [fragment_paths(spec, part, parts)[1] for part in range(parts)]

    # Every expected temporary file must exist before combining.
    for path in [*weight_paths, *admin_paths]:
        require(path.is_file(), f"Missing fragment: {path}")

    weights = pd.concat([pd.read_csv(path) for path in weight_paths], ignore_index=True)
    summary = pd.concat([pd.read_csv(path, dtype="string") for path in admin_paths], ignore_index=True)

    # Admin IDs are read as strings so they keep their original form.
    # Convert the population and land-area columns back to numeric.
    numeric_summary = [
        "population_total_landscan2011", "population_covered",
        "positive_population_pixels_covered", "land_area_total_gpw2010",
        "land_area_points_total", "land_area_covered_km2",
        "land_area_points_covered",
    ]

    summary[numeric_summary] = summary[numeric_summary].apply(pd.to_numeric, errors="raise")
    expected = read_admins(spec)

    # The combined chunks should reproduce the shapefile exactly.
    # These checks catch missing admin units, duplicate admin units, and
    # overlapping admin-grid rows.
    require(len(summary) == len(expected), "Admin count differs from shapefile")
    require(not summary.region_id.duplicated().any(), "Admin fragments overlap")
    require(set(summary.region_id) == set(expected.region_id), "Admin IDs differ from shapefile")
    require(
        not weights.duplicated(["region_id", "grid_row", "grid_column"]).any(),
        "Weight fragments overlap",
    )

    return weights, summary


def normalize_weights(weights, summary):
    # Population weight:
    # population in one CHIRPS cell / total matched population for that admin.
    #
    # Area weight:
    # land area in one CHIRPS cell / total matched land area for that admin.
    weights = weights.copy()
    summary = summary.copy()

    # Total population and land area represented across CHIRPS cells within
    # each admin unit.
    pop_total = weights.groupby("region_id").population.transform("sum")
    area_total = weights.groupby("region_id").land_area_km2.transform("sum")

    weights["popwt"] = np.divide(
        weights.population, pop_total,
        out=np.zeros(len(weights)), where=pop_total > 0,
    )
    weights["areawt"] = np.divide(
        weights.land_area_km2, area_total,
        out=np.zeros(len(weights)), where=area_total > 0,
    )

    # Some admin units have no LandScan population covered by the CHIRPS grid.
    # For those units, use land-area weights in place of population weights and
    # record the substitution in the admin summary.
    no_population = set(summary.loc[summary.population_covered <= 0, "region_id"])
    fallback = weights.region_id.isin(no_population) & (area_total > 0)

    weights.loc[fallback, "popwt"] = weights.loc[fallback, "areawt"]

    summary["population_weight_fallback"] = np.where(
        summary.region_id.isin(no_population), "area", "none"
    )

    # Fraction of LandScan population and GPW land area covered by CHIRPS.
    summary["population_coverage_fraction"] = np.divide(
        summary.population_covered, summary.population_total_landscan2011,
        out=np.zeros(len(summary)), where=summary.population_total_landscan2011 > 0,
    )

    summary["area_coverage_fraction"] = np.divide(
        summary.land_area_covered_km2, summary.land_area_total_gpw2010,
        out=np.zeros(len(summary)), where=summary.land_area_total_gpw2010 > 0,
    )

    # Check normalized weight sums and count CHIRPS cells by admin unit.
    sums = (
        weights.groupby("region_id", as_index=False)[["popwt", "areawt"]]
        .sum()
        .rename(columns={"popwt": "popwt_sum", "areawt": "areawt_sum"})
    )

    counts = weights.groupby("region_id", as_index=False).size().rename(
        columns={"size": "climate_grid_cells"}
    )

    summary = summary.merge(sums, on="region_id", how="left")
    summary = summary.merge(counts, on="region_id", how="left")

    # Admin units with no matched CHIRPS cells do not appear in the weight sums.
    # Keep their summary counts as zeros.
    summary[["popwt_sum", "areawt_sum", "climate_grid_cells"]] = summary[
        ["popwt_sum", "areawt_sum", "climate_grid_cells"]
    ].fillna(0)

    # Mark admin units with incomplete or no CHIRPS coverage.
    summary["coverage_status"] = "full"

    partial = (
        (summary.population_coverage_fraction < 0.999)
        | (summary.area_coverage_fraction < 0.999)
    )

    summary.loc[partial, "coverage_status"] = "partial"
    summary.loc[summary.areawt_sum == 0, "coverage_status"] = "uncovered"

    return weights, summary


def handle_uncovered_admins(spec, weights, summary):
    # This is separate from normal weight construction.
    # Some small polygons contain no CHIRPS grid-cell center.
    if spec.uncovered_cell_rule == "nearest_grid_cell":
        # For countries using this rule, use the CHIRPS cell containing a
        # representative point inside the polygon.
        grid = read_grid(climate_file(spec.pilot_year))
        expected = read_admins(spec)

        uncovered = summary.loc[summary.coverage_status == "uncovered", "region_id"].tolist()

        if uncovered:
            admin_lookup = expected.set_index("region_id")
            additions = []

            for region_id in uncovered:
                # `representative_point()` gives a point guaranteed to lie inside
                # the polygon.
                point = admin_lookup.loc[region_id].geometry.representative_point()

                grid_row, grid_column, inside = grid.point_indices(
                    np.array([point.y]), np.array([point.x])
                )

                require(bool(inside[0]), f"{region_id} representative point is outside CHIRPS")

                # These admin units use one CHIRPS cell with weight 1 for both
                # population and area weighting.
                additions.append(
                    {
                        "region_id": region_id,
                        "grid_row": int(grid_row[0]),
                        "grid_column": int(grid_column[0]),
                        "population": 0.0,
                        "land_area_km2": 0.0,
                        "popwt": 1.0,
                        "areawt": 1.0,
                    }
                )

            weights = pd.concat([weights, pd.DataFrame(additions)], ignore_index=True)

            summary.loc[summary.region_id.isin(uncovered), "popwt_sum"] = 1.0
            summary.loc[summary.region_id.isin(uncovered), "areawt_sum"] = 1.0
            summary.loc[summary.region_id.isin(uncovered), "climate_grid_cells"] = 1
            summary.loc[summary.region_id.isin(uncovered), "coverage_status"] = "nearest_grid_cell"

            print(f"nearest-grid fallback admins={len(uncovered)}")

    elif spec.uncovered_cell_rule != "keep_uncovered":
        require(False, f"Unknown uncovered-cell rule: {spec.uncovered_cell_rule}")

    return weights, summary


def combine(spec, parts, overwrite):
    # Run after every chunk has finished.
    # Combine temporary files, check admin coverage, normalize weights, handle
    # tiny uncovered polygons, and write the final outputs.
    destination = weights_file(spec)
    summary_destination = admin_file(spec)

    if destination.exists() and summary_destination.exists() and not overwrite:
        print(f"existing files kept: {destination}")
        return

    weights, summary = combine_fragments(spec, parts)
    weights, summary = normalize_weights(weights, summary)
    weights, summary = handle_uncovered_admins(spec, weights, summary)

    # Every admin unit with a CHIRPS cell should have both weights sum to one.
    covered = summary.coverage_status != "uncovered"
    require(np.allclose(summary.loc[covered, "popwt_sum"], 1), "Population weights do not sum to one")
    require(np.allclose(summary.loc[covered, "areawt_sum"], 1), "Area weights do not sum to one")

    grid = read_grid(climate_file(spec.pilot_year))

    # Add CHIRPS latitude and longitude for each grid cell.
    # This makes the final weight file easier to inspect without reopening
    # the NetCDF file.
    rows = weights.grid_row.to_numpy(dtype="int64")
    columns = weights.grid_column.to_numpy(dtype="int64")

    weights["latitude"] = grid.latitude[rows]
    weights["longitude"] = grid.longitude[columns]

    # Add the original country-specific admin IDs to each weight row.
    id_lookup = summary.set_index("region_id").loc[:, spec.id_columns]
    weights = weights.join(id_lookup, on="region_id")

    # Keep a fixed column order in the final weight file.
    order = [
        "region_id", *spec.id_columns, "grid_row", "grid_column",
        "latitude", "longitude", "population", "land_area_km2",
        "popwt", "areawt",
    ]

    atomic_csv(weights.loc[:, order], destination)
    atomic_csv(summary, summary_destination)

    print(f"created {destination} ({len(weights)} rows)")
    print(summary.coverage_status.value_counts().to_string())


# -----------------------------
# Main
# -----------------------------


def main():
    args = arguments()
    spec = country(args.country)

    # Fail early if either large source dataset is unavailable.
    require(LANDSCAN.is_file(), f"Missing LandScan raster: {LANDSCAN}")
    require(GPW_LAND_AREA.is_dir(), f"Missing GPW land-area data: {GPW_LAND_AREA}")

    # Run either one polygon chunk or the final combine step.
    if args.combine:
        combine(spec, args.parts, args.overwrite)
    else:
        make_fragment(spec, args.part, args.parts, args.overwrite)


if __name__ == "__main__":
    try:
        main()
    except CheckError as error:
        # Put the failed check in the Slurm log before the job exits.
        print(f"CHECK FAILED: {error}", file=sys.stderr)
        raise SystemExit(2)
