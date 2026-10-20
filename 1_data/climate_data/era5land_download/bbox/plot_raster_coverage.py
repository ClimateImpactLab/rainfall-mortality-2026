#!/usr/bin/env python3
"""Plot ERA5-Land raster coverage by region.

Reads the daily NetCDF files in `/project/cil/gcp/climate/ERA5-LAND/raw/daily`
and maps the latitude/longitude extent covered by each region folder.

Outputs are written to:
`/project/cil/gcp/estimation/rainfall-mortality/era5land_domains/plots`
"""

from __future__ import annotations

import os
from pathlib import Path

DEFAULT_PROJ = Path("/project/cil/home_dirs/mdefranciosi/envs/era5land/share/proj")
if "PROJ_LIB" not in os.environ and (DEFAULT_PROJ / "proj.db").exists():
    # Help geopandas find projection files on RCC.
    os.environ["PROJ_LIB"] = str(DEFAULT_PROJ)

import geopandas as gpd
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import xarray as xr


# =============================================================================
# 1. Paths and Plot Settings
# =============================================================================

DOMAIN_ROOT = Path(
    "/project/cil/gcp/estimation/rainfall-mortality/era5land_domains"
)
RAW_DAILY_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND/raw/daily")
FIGDIR = DOMAIN_ROOT / "plots"
WORLD_SHP = Path(
    "/home/mdefranciosi/.conda/pkgs/pyogrio-0.12.1-py312h053e1f3_0/"
    "lib/python3.12/site-packages/pyogrio/tests/fixtures/"
    "naturalearth_lowres/naturalearth_lowres.shp"
)

# One color per current region/component name. These are only for plots.
COLORS = {
    "asia_combined": "#1b9e77",
    "australia": "#7570b3",
    "brazil": "#d95f02",
    "europe": "#e7298a",
    "mexico": "#66a61e",
    "usa": "#1f78b4",
    "india": "#117733",
    "asia_east": "#44aa99",
    "latam": "#cc6677",
    "brazil_east": "#aa4499",
    "mexico_south": "#999933",
}

# Some current folder names are misleading. Use clearer labels on the main map.
MAIN_REGION_LABELS = {
    "asia_combined": "asia",
    "brazil": "latin america",
    "mexico": "north america",
}


# =============================================================================
# 2. Read Raster Coverage
# =============================================================================

def first_file_by_variable(region_dir: Path) -> list[Path]:
    """Return one annual file per variable for a region.

    The script only needs grid extents, so it reads one file per variable rather
    than scanning every year. The consistency check below catches variables with
    different coordinates.
    """
    files = []

    # Each variable has its own folder in the final daily data. One annual file
    # per variable is enough to read the grid extent.
    for variable_dir in sorted(p for p in region_dir.iterdir() if p.is_dir()):
        matches = sorted(variable_dir.glob("*.nc4"))
        if matches:
            files.append(matches[0])
    return files


def file_grid_extent(path: Path) -> dict[str, float | int]:
    """Read coordinate bounds from a NetCDF header without loading data values."""
    with xr.open_dataset(path, decode_times=False) as ds:
        if "latitude" not in ds.coords or "longitude" not in ds.coords:
            raise ValueError(f"Missing latitude/longitude coordinates: {path}")

        # Reading coordinates is cheap. We do not load the climate values.
        lat = ds["latitude"].values
        lon = ds["longitude"].values

    return {
        "lat_min": float(lat.min()),
        "lat_max": float(lat.max()),
        "lon_min": float(lon.min()),
        "lon_max": float(lon.max()),
        "lat_count": int(lat.size),
        "lon_count": int(lon.size),
    }


def region_grid_extent(region_dir: Path) -> dict[str, float | int | str]:
    """Check a region's variables share one grid and return that grid extent."""
    files = first_file_by_variable(region_dir)
    if not files:
        raise FileNotFoundError(f"No annual .nc4 files found under {region_dir}")

    # The merged annual files should all have the same grid inside a region.
    # If one variable has a different grid, the maps would hide a real problem.
    first = file_grid_extent(files[0])
    for path in files[1:]:
        current = file_grid_extent(path)
        if current != first:
            raise ValueError(
                "Variables do not share the same grid for "
                f"{region_dir.name}: {files[0]} vs {path}"
            )

    return {"region": region_dir.name, **first}


def read_regions() -> dict[str, dict]:
    """Build region coverage from the climate files currently on disk."""
    if not RAW_DAILY_ROOT.exists():
        raise FileNotFoundError(f"Daily climate directory not found: {RAW_DAILY_ROOT}")

    regions = {}

    # Read every region folder that exists in the final daily climate directory.
    for region_dir in sorted(p for p in RAW_DAILY_ROOT.iterdir() if p.is_dir()):
        regions[region_dir.name] = region_grid_extent(region_dir)
    return regions


# =============================================================================
# 3. Plot Helpers
# =============================================================================

def draw_world_guides(ax) -> None:
    """Set common world-map styling used by all three plots."""
    ax.set_xlim(-180, 180)
    ax.set_ylim(-60, 85)
    ax.set_aspect("equal", adjustable="box")
    ax.set_facecolor("#f8fbfd")

    # Country outlines are just a visual guide. The boxes still come from the
    # climate rasters, not from this shapefile.
    if WORLD_SHP.exists():
        world = gpd.read_file(WORLD_SHP)
        world.boundary.plot(ax=ax, color="#9aa6ad", linewidth=0.35, alpha=0.75)
    ax.grid(color="#d4dbe0", linewidth=0.45, linestyle="-", alpha=0.8)
    ax.axhline(0, color="#9aa6ad", linewidth=0.7)
    ax.axvline(0, color="#9aa6ad", linewidth=0.7)
    ax.set_xlabel("Longitude")
    ax.set_ylabel("Latitude")
    ax.set_xticks(range(-180, 181, 30))
    ax.set_yticks(range(-60, 91, 15))
    for spine in ax.spines.values():
        spine.set_color("#7f8b92")
        spine.set_linewidth(0.8)


def add_box(ax, row: dict, label: str, *, alpha: float = 0.15, lw: float = 2.0) -> None:
    # Draw the full rectangular extent of one raster folder.
    color = COLORS[label]
    width = row["lon_max"] - row["lon_min"]
    height = row["lat_max"] - row["lat_min"]
    patch = Rectangle(
        (row["lon_min"], row["lat_min"]),
        width,
        height,
        facecolor=color,
        edgecolor=color,
        linewidth=lw,
        alpha=alpha,
        label=label,
    )
    ax.add_patch(patch)


def add_outline(ax, row: dict, label: str, *, lw: float = 4.0, linestyle: str = "-") -> None:
    # Use a thick outline for small patches that are hard to see otherwise.
    color = COLORS[label]
    width = row["lon_max"] - row["lon_min"]
    height = row["lat_max"] - row["lat_min"]
    patch = Rectangle(
        (row["lon_min"], row["lat_min"]),
        width,
        height,
        facecolor="none",
        edgecolor=color,
        linewidth=lw,
        linestyle=linestyle,
        alpha=1.0,
        zorder=10,
    )
    ax.add_patch(patch)


def display_label(region: str, labels: dict[str, str] | None = None) -> str:
    if labels is None:
        labels = {}
    return labels.get(region, region).replace("_", " ")


def annotate_box(
    ax,
    row: dict,
    label: str,
    dx: float = 0,
    dy: float = 0,
    labels: dict[str, str] | None = None,
) -> None:
    # Put the label near the middle of the box. Offsets are used where boxes
    # overlap too much.
    x = (row["lon_min"] + row["lon_max"]) / 2 + dx
    y = (row["lat_min"] + row["lat_max"]) / 2 + dy
    ax.text(
        x,
        y,
        display_label(label, labels).replace(" ", "\n"),
        ha="center",
        va="center",
        fontsize=8.5,
        color="#20272b",
        bbox={"facecolor": "white", "edgecolor": "none", "alpha": 0.72, "pad": 1.8},
    )


def add_legend(
    ax,
    regions: list[str],
    opaque_regions: set[str] | None = None,
    labels: dict[str, str] | None = None,
) -> None:
    # The legend uses stronger fill for patch regions when those patches are
    # drawn with thicker outlines on the map.
    opaque_regions = opaque_regions or set()
    handles = []
    for region in regions:
        is_opaque = region in opaque_regions
        handles.append(
            Rectangle(
                (0, 0),
                1,
                1,
                facecolor=COLORS[region],
                edgecolor=COLORS[region],
                alpha=0.95 if is_opaque else 0.25,
                linewidth=2.8 if is_opaque else 1.4,
            )
        )
    legend_labels = [display_label(r, labels) for r in regions]
    ax.legend(
        handles,
        legend_labels,
        loc="lower center",
        bbox_to_anchor=(0.5, -0.24),
        ncol=3,
        frameon=False,
        fontsize=9,
    )


def plot_main(regions: dict[str, dict]) -> None:
    # Main map: final folders that should be used for climate aggregation.
    names = ["asia_combined", "australia", "brazil", "europe", "mexico"]
    fig, ax = plt.subplots(figsize=(14, 7.5))
    draw_world_guides(ax)
    for name in names:
        add_box(ax, regions[name], name)

    # Move a few labels so they do not sit on top of each other.
    label_offsets = {
        "mexico": (12, -8),
        "brazil": (0, -2),
        "europe": (0, 0),
        "asia_combined": (0, 0),
        "australia": (0, 0),
    }
    for name in names:
        dx, dy = label_offsets.get(name, (0, 0))
        annotate_box(ax, regions[name], name, dx=dx, dy=dy, labels=MAIN_REGION_LABELS)
    add_legend(ax, names, labels=MAIN_REGION_LABELS)
    ax.set_title("ERA5-Land Climate Data Domains (bbox)", pad=14)
    fig.subplots_adjust(bottom=0.24, left=0.06, right=0.98, top=0.9)
    fig.savefig(FIGDIR / "era5land_main_region_bboxes.png", dpi=220)
    fig.savefig(FIGDIR / "era5land_main_region_bboxes.pdf")
    plt.close(fig)


def plot_components(regions: dict[str, dict]) -> None:
    # Component map: old pieces that were merged into the final folders.
    names = ["india", "asia_east", "usa", "mexico_south", "latam", "brazil_east"]
    fig, ax = plt.subplots(figsize=(14, 7.5))
    draw_world_guides(ax)
    for name in names:
        add_box(ax, regions[name], name, alpha=0.18, lw=2.1)

    # These two patches are tiny on a world map, so outline them heavily.
    add_outline(ax, regions["mexico_south"], "mexico_south", lw=5.0)
    add_outline(ax, regions["brazil_east"], "brazil_east", lw=5.0)
    offsets = {
        "india": (-8, 0),
        "asia_east": (5, 0),
        "usa": (0, 10),
        "mexico_south": (0, -7),
        "latam": (-10, 0),
        "brazil_east": (17, 3),
    }
    for name in names:
        dx, dy = offsets.get(name, (0, 0))
        annotate_box(ax, regions[name], name, dx=dx, dy=dy)

    # Add the merge relationships directly on the plot.
    ax.text(99, 61, "india + asia_east -> asia_combined", fontsize=9, ha="center")
    ax.text(-116, 77, "usa + mexico_south -> mexico", fontsize=9, ha="center")
    ax.text(-72, -56, "latam + brazil_east -> brazil", fontsize=9, ha="center")
    add_legend(ax, names, opaque_regions={"mexico_south", "brazil_east"})
    ax.set_title("ERA5-Land Component Domains Used to Build Combined Regions", pad=14)
    fig.subplots_adjust(bottom=0.24, left=0.06, right=0.98, top=0.9)
    fig.savefig(FIGDIR / "era5land_component_region_bboxes.png", dpi=220)
    fig.savefig(FIGDIR / "era5land_component_region_bboxes.pdf")
    plt.close(fig)


def plot_component_zoom(regions: dict[str, dict]) -> None:
    # Zoom map: make the small Mexico and Brazil patches readable.
    fig, axes = plt.subplots(1, 2, figsize=(14, 6.2))

    # Mexico view: the patch is a thin strip south of the USA box.
    ax = axes[0]
    draw_world_guides(ax)
    ax.set_xlim(-130, -45)
    ax.set_ylim(5, 35)
    for name in ["usa", "mexico_south", "latam"]:
        add_box(ax, regions[name], name, alpha=0.16, lw=2.0)
    add_outline(ax, regions["mexico_south"], "mexico_south", lw=6.0)
    annotate_box(ax, regions["mexico_south"], "mexico_south", dx=0, dy=-2.7)
    ax.text(
        -87,
        31,
        "mexico_south is only five 0.1-degree latitude rows\n"
        "(14.5N to 14.9N) appended below the USA domain",
        fontsize=9,
        ha="center",
        bbox={"facecolor": "white", "edgecolor": "none", "alpha": 0.78, "pad": 3},
    )
    ax.set_title("Zoom: Mexico South Strip")

    # Brazil view: the patch is only the small eastern edge that LATAM missed.
    ax = axes[1]
    draw_world_guides(ax)
    ax.set_xlim(-42, -32)
    ax.set_ylim(-12, -3)
    for name in ["latam", "brazil_east"]:
        add_box(ax, regions[name], name, alpha=0.16, lw=2.0)
    add_outline(ax, regions["brazil_east"], "brazil_east", lw=6.0)
    annotate_box(ax, regions["brazil_east"], "brazil_east", dx=0.5, dy=0.2)
    ax.text(
        -37,
        -3.8,
        "brazil_east is a small coastal extension\n"
        "adding eastern longitudes to LATAM",
        fontsize=9,
        ha="center",
        bbox={"facecolor": "white", "edgecolor": "none", "alpha": 0.78, "pad": 3},
    )
    ax.set_title("Zoom: Brazil East Extension")

    handles = [
        Rectangle(
            (0, 0),
            1,
            1,
            facecolor=COLORS[r],
            edgecolor=COLORS[r],
            alpha=0.95 if r in {"mexico_south", "brazil_east"} else 0.25,
            linewidth=2.8 if r in {"mexico_south", "brazil_east"} else 1.4,
        )
        for r in ["usa", "latam", "mexico_south", "brazil_east"]
    ]
    labels = ["usa", "latam", "mexico south", "brazil east"]
    fig.legend(handles, labels, loc="lower center", ncol=4, frameon=False, fontsize=9)
    fig.suptitle("ERA5-Land Small Component Regions: Zoomed Views", y=0.96)
    fig.subplots_adjust(bottom=0.16, left=0.06, right=0.98, top=0.87, wspace=0.16)
    fig.savefig(FIGDIR / "era5land_small_component_region_zooms.png", dpi=220)
    fig.savefig(FIGDIR / "era5land_small_component_region_zooms.pdf")
    plt.close(fig)


def main() -> None:
    FIGDIR.mkdir(parents=True, exist_ok=True)

    # Read the raster boxes once, then reuse them for all three maps.
    regions = read_regions()
    plot_main(regions)
    plot_components(regions)
    plot_component_zoom(regions)


if __name__ == "__main__":
    main()
