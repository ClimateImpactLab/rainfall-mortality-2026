#!/usr/bin/env python3
"""
01_make_state_weights.py

Build fixed ERA5-Land state-grid weights for the Young-Hsiang state-month panel.

The Young-Hsiang/Census 2016 shapefile supplies the state polygons. The
Young-Hsiang state-month panel defines the tropical-cyclone-prone state sample.
Population weights use LandScan 2011. Area weights use GPW 2010 land-area
points. One ERA5-Land USA file is used only to read the grid. The finished
weights are reused for every year.

Inputs:
- Young-Hsiang/Census 2016 U.S. state shapefile
- Young-Hsiang state-month panel, used for the state list
- LandScan 2011 population raster
- GPW 2010 land-area point table
- one ERA5-Land USA NetCDF file used to read the grid

Outputs:
- state x ERA5-Land grid-cell weights with `popwt` and `areawt`
- state summary CSV with population and land-area checks

This reads large raster and point files.
"""

# ------------------
# Packages
# ------------------

from pathlib import Path
import sys

import geopandas as gpd
import numpy as np
import pandas as pd
import pyarrow.dataset as pads
import rasterio
from rasterio.features import geometry_mask
from rasterio.windows import Window, from_bounds


ERA5_ADMIN = Path(__file__).resolve().parents[1] / "era5land_admin"
sys.path.insert(0, str(ERA5_ADMIN))

# Reuse the ERA5-Land grid reader and CSV/check helpers from the admin
# aggregation folder.
from common import CheckError, atomic_csv, read_grid, require  # noqa: E402


# -----------------------------
# Paths
# -----------------------------

# Young-Hsiang tropical-cyclone mortality replication data.
YH_RAW = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/external_data/"
    "young_hsiang_tc_mortality/raw"
)

# 2016 Census state polygons used by the Young-Hsiang panel.
STATE_SHAPEFILE = YH_RAW / "data/cb_2016_us_state_20m/cb_2016_us_state_20m.shp"

# State-month mortality panel, its states define the TC-prone sample.
YH_PANEL = YH_RAW / "data/DATA_hurricane_mortality_temp_month_state_19302015.dta"

# One USA ERA5-Land precipitation file used only to read the grid.
GRID_FILE = Path(
    "/project/cil/gcp/climate/ERA5-LAND/raw/daily/usa/tp_total/"
    "era5land_usa_tp_total_1968.nc4"
)

# LandScan 2011 population raster used for population weights.
LANDSCAN = Path(
    "/project/cil/battuta_shares/gcp/social/sources/Landscan2011/"
    "RasterGISbinary/lspop2011.flt"
)

# GPW 2010 land-area point table used for area weights.
GPW_LAND_AREA = Path("/project/cil/gcp/temp_data/gpw_2010_land_area_points")

# Fixed state-to-ERA5-Land weights written outside the repo.
WEIGHT_DIR = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/climate_data/weights/"
    "landscan2011/ERA5-LAND/USA_STATE_MONTH"
)
WEIGHT_FILE = WEIGHT_DIR / "era5land_usa_state_month_weights_landscan2011.csv"

# State summary file with IDs and population/land-area coverage totals.
ADMIN_FILE = WEIGHT_DIR / "era5land_usa_state_month_admins.csv"


# -----------------------------
# State shapefile
# -----------------------------

def read_states():
    # Young-Hsiang uses the 2016 Census state polygons.
    states = gpd.read_file(STATE_SHAPEFILE, engine="pyogrio")

    keep = ["STATEFP", "STUSPS", "NAME", "geometry"]
    missing = [column for column in keep if column not in states.columns]
    require(not missing, f"Missing shapefile columns: {missing}")

    # ERA5-Land grid coordinates are longitude/latitude.
    if states.crs is None:
        raise CheckError("State shapefile has no CRS")
    if states.crs.to_epsg() != 4326:
        states = states.to_crs(4326)

    states = states.loc[:, keep].copy()
    states["geometry"] = states.geometry.make_valid()
    states["stfips"] = states["STATEFP"].astype(int)
    states["state_abbrev"] = states["STUSPS"].astype(str)
    states["adm_name"] = states["NAME"].str.upper()

    # region_id follows the naming used by the other admin climate files.
    states["region_id"] = "USA_" + states["STATEFP"].astype(str).str.zfill(2)

    # Representative longitude is only used to keep output ordering stable.
    states["_longitude"] = states.geometry.representative_point().x

    require(states.geometry.notna().all(), "State shapefile has missing geometry")
    require((~states.geometry.is_empty).all(), "State shapefile has empty geometry")
    require(not states["stfips"].duplicated().any(), "Duplicate state FIPS")

    return states.sort_values(["_longitude", "stfips"]).reset_index(drop=True)


def keep_sample_states(states):
    # The shapefile provides polygons, the panel defines the TC-prone states.
    panel = pd.read_stata(YH_PANEL, columns=["stfips", "state_abbrev"])

    # The source panel has one blank stfips=99 row. It is not a real state.
    panel = panel.loc[panel["state_abbrev"].fillna("").astype(str).str.strip() != ""]
    sample_fips = set(panel["stfips"].dropna().astype(int).unique())
    require(len(sample_fips) > 0, "No state FIPS found in Young-Hsiang panel")

    # Every panel state should have a matching 2016 Census polygon.
    states = states.loc[states["stfips"].isin(sample_fips)].copy()
    missing = sorted(sample_fips - set(states["stfips"]))
    require(not missing, f"Sample states missing from shapefile: {missing}")
    require(not states.empty, "No sample states left after filtering")
    return states.reset_index(drop=True)


# -----------------------------
# Population Weights
# -----------------------------

def clipped_window(dataset, bounds):
    # Read only the LandScan raster window around one state.
    requested = from_bounds(*bounds, transform=dataset.transform)
    requested = requested.round_offsets().round_lengths()
    full = Window(0, 0, dataset.width, dataset.height)
    try:
        return requested.intersection(full)
    except rasterio.errors.WindowError:
        return None


def population_cells(dataset, geometry, grid):
    # LandScan pixels enter a state when their centers fall inside the polygon.
    window = clipped_window(dataset, geometry.bounds)
    if window is None:
        return {}, 0.0, 0.0, 0

    data = dataset.read(1, window=window, masked=True)
    transform = dataset.window_transform(window)
    inside = geometry_mask(
        [geometry.__geo_interface__],
        out_shape=data.shape,
        transform=transform,
        invert=True,
        all_touched=False,
    )
    values = np.ma.filled(data, np.nan).astype("float64", copy=False)
    valid = inside & np.isfinite(values) & (values >= 0)
    total = float(values[valid].sum())

    # Zero-population pixels do not contribute to population weights.
    row, column = np.nonzero(valid & (values > 0))
    if len(row) == 0:
        return {}, total, 0.0, 0

    # Assign each LandScan pixel center to an ERA5-Land cell.
    longitude = transform.c + (column + 0.5) * transform.a
    latitude = transform.f + (row + 0.5) * transform.e
    grid_row, grid_column, covered = grid.point_indices(latitude, longitude)
    population = values[row, column]

    # Several LandScan pixels can map to the same ERA5-Land cell.
    encoded = grid_row[covered] * len(grid.longitude) + grid_column[covered]
    unique, inverse = np.unique(encoded, return_inverse=True)
    sums = np.bincount(inverse, weights=population[covered])

    cells = {
        (int(code // len(grid.longitude)), int(code % len(grid.longitude))): float(value)
        for code, value in zip(unique, sums, strict=True)
    }
    return cells, total, float(population[covered].sum()), int(covered.sum())


def population_frame(states, grid):
    # Build state-grid population rows and one coverage summary row per state.
    rows = []
    summaries = []

    with rasterio.open(LANDSCAN) as population:
        for number, state in enumerate(states.itertuples(index=False), start=1):
            cells, total, covered, pixels = population_cells(population, state.geometry, grid)

            for (grid_row, grid_column), value in cells.items():
                rows.append({
                    "region_id": state.region_id,
                    "grid_row": grid_row,
                    "grid_column": grid_column,
                    "population": value,
                })

            summaries.append({
                "region_id": state.region_id,
                "population_total_landscan2011": total,
                "population_covered": covered,
                "positive_population_pixels_covered": pixels,
            })
            print(f"population {number}/{len(states)} {state.state_abbrev}", flush=True)

    return pd.DataFrame(rows), pd.DataFrame(summaries)


# -----------------------------
# Area Weights
# -----------------------------

def land_area_frame(states, grid):
    # Read GPW land-area points inside the overall bounds of the sample states.
    dataset = pads.dataset(GPW_LAND_AREA, format="parquet")
    xmin, ymin, xmax, ymax = states.total_bounds
    keep = (
        (pads.field("longitude") >= xmin) & (pads.field("longitude") <= xmax)
        & (pads.field("latitude") >= ymin) & (pads.field("latitude") <= ymax)
    )

    # GPW points are assigned first to states, then to ERA5-Land cells.
    joined = []
    state_columns = ["region_id", "geometry"]
    for batch in dataset.to_batches(
        columns=["longitude", "latitude", "land_area"], filter=keep, batch_size=500_000
    ):
        points = batch.to_pandas()
        geo = gpd.GeoDataFrame(
            points, geometry=gpd.points_from_xy(points.longitude, points.latitude), crs="EPSG:4326"
        )
        found = gpd.sjoin(
            geo, states.loc[:, state_columns], how="inner", predicate="within"
        ).drop(columns=["geometry", "index_right"])
        if len(found):
            joined.append(found)

    require(joined, "No GPW land-area points matched the state shapefile")
    points = pd.concat(joined, ignore_index=True)
    points["land_area"] = pd.to_numeric(points["land_area"], errors="raise")
    require((points["land_area"] > 0).all(), "GPW land area must be positive")

    grid_row, grid_column, covered = grid.point_indices(
        points.latitude.to_numpy(), points.longitude.to_numpy()
    )
    points["grid_row"] = grid_row
    points["grid_column"] = grid_column
    points["covered"] = covered

    # Keep state-level land-area totals for the summary file.
    summary = points.groupby("region_id", as_index=False).agg(
        land_area_total_gpw2010=("land_area", "sum"),
        land_area_points_total=("land_area", "size"),
    )
    covered_summary = points.loc[points.covered].groupby("region_id", as_index=False).agg(
        land_area_covered_km2=("land_area", "sum"),
        land_area_points_covered=("land_area", "size"),
    )
    summary = summary.merge(covered_summary, on="region_id", how="left")

    # Sum GPW land area to state x ERA5-Land cell.
    weights = (
        points.loc[points.covered]
        .groupby(["region_id", "grid_row", "grid_column"], as_index=False)
        .land_area.sum()
        .rename(columns={"land_area": "land_area_km2"})
    )
    return weights, summary


# -----------------------------
# Final Files
# -----------------------------

def normalize_weights(frame, value_column, output_column):
    # Cell totals divided by state totals, weights sum to one within state.
    totals = frame.groupby("region_id")[value_column].transform("sum")
    return frame.assign(**{output_column: frame[value_column] / totals})


def build_weights(states, grid):
    # Build population weights, build area weights, then normalize each.
    pop, pop_summary = population_frame(states, grid)
    area, area_summary = land_area_frame(states, grid)
    pop = normalize_weights(pop, "population", "popwt")
    area = normalize_weights(area, "land_area_km2", "areawt")

    # Keep grid cells that have population weight, area weight, or both.
    weights = pop.merge(area, on=["region_id", "grid_row", "grid_column"], how="outer")
    weights[["popwt", "areawt"]] = weights[["popwt", "areawt"]].fillna(0)
    weights = weights.sort_values(["region_id", "grid_row", "grid_column"])

    summary = (
        states.drop(columns=["geometry", "_longitude"])
        .merge(pop_summary, on="region_id", how="left")
        .merge(area_summary, on="region_id", how="left")
    )
    return weights, summary


def check_weights(weights, states):
    require(not weights.empty, "Weight file would be empty")

    # Each state x ERA5-Land cell should appear once.
    require(
        not weights[["region_id", "grid_row", "grid_column"]].duplicated().any(),
        "Duplicate state-grid rows",
    )

    sums = weights.groupby("region_id", as_index=False).agg(
        popwt_sum=("popwt", "sum"), areawt_sum=("areawt", "sum")
    )

    # Every Young-Hsiang sample state should have at least one weighted cell.
    missing = sorted(set(states.region_id) - set(sums.region_id))
    require(not missing, f"States with no weights: {missing}")

    # Population and area weights should each sum to one within state.
    require(np.allclose(sums.popwt_sum, 1), "Population weights do not sum to one")
    require(np.allclose(sums.areawt_sum, 1), "Area weights do not sum to one")


def main():
    # Read the ERA5-Land grid and the Young-Hsiang state shapes.
    WEIGHT_DIR.mkdir(parents=True, exist_ok=True)
    grid = read_grid(GRID_FILE)
    states = keep_sample_states(read_states())

    # Build fixed weights and check them before writing.
    weights, summary = build_weights(states, grid)
    check_weights(weights, states)

    # Save the state summary and state-grid weights.
    atomic_csv(summary, ADMIN_FILE)
    atomic_csv(weights.loc[:, ["region_id", "grid_row", "grid_column", "popwt", "areawt"]], WEIGHT_FILE)
    print(f"created {ADMIN_FILE}")
    print(f"created {WEIGHT_FILE}")


if __name__ == "__main__":
    # Print clean messages for expected input and weight-check failures.
    try:
        main()
    except CheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
