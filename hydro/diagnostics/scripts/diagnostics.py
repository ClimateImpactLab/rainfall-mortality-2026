# ERA5-Land monthly diagnostics, run over both processing vintages side by side.
#
# Purpose: compare the original monthly files against the test vintage to confirm
#   the ocean-cell missing-value issue is resolved. The original vintage 0-fills
#   ocean cells; the test vintage keeps them as NaN
#
# Scope: prevalence (how often) and maps (where), for three checks -- ocean
#   masking, negative rainfall, and missing rainfall_flow
#
# Inputs:  {vintage}/{region}_monthly.nc4       var rainfall
#          {vintage}/{region}_monthly_flow.nc4  var rainfall_flow
#          lsm.area-subset.90.180.-90.-180.nc   ERA5-Land land-sea mask
#          where {vintage} is  .../processed/monthly       -> "original"
#                              .../processed/monthly/test  -> "test"
#
# Outputs: output/missing_weather/    summary csv + cell-status map
#          output/negative_rainfall/  summary csv + frequency map + seasonal chart
#          output/missing_flow/       summary csv, by-month csv, 2 maps
#          Vintage-comparison figures have two panels, original (left) vs test
#          (right), on shared color/axis scales so the panels are directly
#          comparable. Negative rainfall is original-only: the test vintage
#          changed nothing about how rainfall is computed. CSVs carry a `vintage`
#          column instead of being split across folders. Figures are .png.
#
# Run: python hydro/diagnostics/scripts/diagnostics.py
#      sbatch hydro/diagnostics/scripts/diagnostics.sh
#

import pathlib
import numpy as np
import pandas as pd
import xarray as xr
import matplotlib
matplotlib.use("Agg")  # runs headless under SLURM
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.colors as mcolors
import cartopy.crs as ccrs
import cartopy.feature as cfeature

# ── Paths ──────────────────────────────────────────────────────────────────────
home_dir   = pathlib.Path("/Volumes/cil") if pathlib.Path("/Volumes/cil").exists() else pathlib.Path("/project/cil")
script_dir = pathlib.Path(__file__).parents[1]

MONTHLY_DIR = home_dir / "gcp/climate/ERA5-LAND/processed/monthly"
LSM_PATH    = home_dir / "gcp/climate/taudem_conus/geo_working/lsm.area-subset.90.180.-90.-180.nc"
OUT_ROOT    = script_dir / "output"

# The two vintages being compared. Order is panel order: original left, test right.
VINTAGE_DIRS = {
    "original": MONTHLY_DIR,
    "test":     MONTHLY_DIR / "test",
}
VINTAGES = list(VINTAGE_DIRS)

# Read 12 months at a time. usa is 888 x 1265 x 888; the full rainfall array is
# ~4 GB as float32 and the flow files are float64, so neither fits comfortably.
TIME_CHUNK = 12

# LSM bin boundaries
SEA_MAX    = 0.2
COAST_MIN  = 0.5
LSM_BINS   = [0, SEA_MAX, COAST_MIN, 0.8, 1.0]
LSM_LABELS = ["sea (<0.2)", "mostly sea (0.2-0.5)", "mostly land (0.5-0.8)", "land (>0.8)"]

MONTH_NAMES = {1: "Jan", 2: "Feb", 3: "Mar", 4: "Apr", 5: "May", 6: "Jun",
               7: "Jul", 8: "Aug", 9: "Sep", 10: "Oct", 11: "Nov", 12: "Dec"}

# ── Load LSM ───────────────────────────────────────────────────────────────────
# Global ERA5-Land land-sea mask on the same 0.1 deg grid; uses 0-360 lon convention.
# LSM values: 0.0 = fully sea, 1.0 = fully land, fractional = coastal mixed.
with xr.open_dataset(LSM_PATH) as _ds:
    lsm_da = _ds["lsm"]
    if "time" in lsm_da.dims:
        lsm_da = lsm_da.isel(time=0)
    lsm_da = lsm_da.load()

# Deduplicate LSM coordinates once (file repeats lon/lat values at its edges)
_, lon_idx = np.unique(lsm_da.longitude.values, return_index=True)
_, lat_idx = np.unique(lsm_da.latitude.values, return_index=True)
lsm_da = lsm_da.isel(longitude=lon_idx, latitude=lat_idx)


def join_lsm(df):
    """Attach lsm and lsm_bin to a frame with lon/lat columns (lon in -180..180)."""
    df["lsm"] = lsm_da.sel(
        longitude=xr.DataArray(df["lon"].values % 360, dims="cell"),
        latitude=xr.DataArray(df["lat"].values, dims="cell"),
        method="nearest",
    ).values
    df["lsm_bin"] = pd.cut(df["lsm"], bins=LSM_BINS, labels=LSM_LABELS, include_lowest=True)
    return df


# ── Per-file rainfall diagnostics ──────────────────────────────────────────────
def diagnose_file(filepath, region):
    """Per-cell missing-data and negative-rainfall counts for one regional file.

    Handles both vintages with the same code. The distinction that matters:

      all_nan     -- no valid value in any month. This is how the test vintage
                     marks ocean.
      always_zero -- has valid values, every one of them exactly 0. This is how
                     the original vintage marks ocean.

    They must be counted separately. `rain == 0` is False for NaN, so an ocean
    cell in the test vintage is neither always_zero nor NaN-aware unless the
    valid-value count is tracked explicitly -- without that, NaN ocean would
    silently be classified as land-with-data and the comparison would show the
    ocean vanishing rather than being correctly masked.
    """
    with xr.open_dataset(filepath) as ds:
        rain     = ds["rainfall"]
        time_dim = rain.dims[0]
        n_time   = rain.sizes[time_dim]
        lon_1d   = rain.longitude.values
        lat_1d   = rain.latitude.values
        t_vals   = pd.DatetimeIndex(rain[time_dim].values)
        shape    = (len(lat_1d), len(lon_1d))

        n_valid_acc = np.zeros(shape, dtype=np.int32)
        n_zero_acc  = np.zeros(shape, dtype=np.int32)
        n_neg_acc   = np.zeros(shape, dtype=np.int32)

        neg_vals_list, neg_by_time, months_list = [], [], []

        for i in range(0, n_time, TIME_CHUNK):
            chunk = rain.isel({time_dim: slice(i, i + TIME_CHUNK)}).values
            n_t   = chunk.shape[0]

            n_valid_acc += (~np.isnan(chunk)).sum(axis=0).astype(np.int32)
            n_zero_acc  += (chunk == 0).sum(axis=0).astype(np.int32)   # NaN == 0 is False
            n_neg_acc   += (chunk < 0).sum(axis=0).astype(np.int32)    # NaN < 0  is False

            neg_vals_list.append(chunk[chunk < 0])
            neg_by_time.extend((chunk < 0).reshape(n_t, -1).sum(axis=1).tolist())
            months_list.extend(t_vals[i:i + TIME_CHUNK].month.tolist())

    all_nan     = n_valid_acc == 0
    always_zero = (~all_nan) & (n_zero_acc == n_valid_acc)
    has_data    = (~all_nan) & (~always_zero)
    neg_vals    = np.concatenate(neg_vals_list) if neg_vals_list else np.array([])

    n_valid_cm    = int(n_valid_acc.sum())
    ever_negative = n_neg_acc > 0

    summary = {
        "region":                region,
        "n_cells":               all_nan.size,
        "n_time_steps":          n_time,
        "date_min":              str(t_vals.min().date()),
        "date_max":              str(t_vals.max().date()),
        "n_all_nan":             int(all_nan.sum()),
        "pct_all_nan":           round(float(all_nan.mean()) * 100, 1),
        "n_always_zero":         int(always_zero.sum()),
        "pct_always_zero":       round(float(always_zero.mean()) * 100, 1),
        "n_has_data":            int(has_data.sum()),
        "pct_has_data":          round(float(has_data.mean()) * 100, 1),
        "n_valid_cell_months":   n_valid_cm,
        "n_cells_w_negative":    int(ever_negative.sum()),
        "pct_cells_w_negative":  round(float(ever_negative.mean()) * 100, 1),
        "min_neg_value_mm_mo":    float(neg_vals.min())      if len(neg_vals) else None,
        "median_neg_value_mm_mo": float(np.median(neg_vals)) if len(neg_vals) else None,
        "mean_neg_value_mm_mo":   float(neg_vals.mean())     if len(neg_vals) else None,
        # Denominator is valid (non-NaN) cell-months, so this is comparable across
        # vintages even though the two mark ocean differently.
        "pct_cell_months_neg":   round(len(neg_vals) / n_valid_cm * 100, 4) if n_valid_cm else 0.0,
    }

    LON, LAT = np.meshgrid(lon_1d, lat_1d)
    cells = pd.DataFrame({
        "region":          region,
        "lon":             LON.ravel(),
        "lat":             LAT.ravel(),
        "all_nan":         all_nan.ravel(),
        "always_zero":     always_zero.ravel(),
        "has_data":        has_data.ravel(),
        "ever_negative":   ever_negative.ravel(),
        "frac_neg_months": (n_neg_acc / n_time).ravel(),
    })

    seasonal_neg = pd.DataFrame({"month": months_list, "neg_cells": neg_by_time})
    return {"summary": summary, "cells": cells, "neg_vals": neg_vals,
            "seasonal_neg": seasonal_neg}


def load_and_diagnose(data_dir):
    """Run diagnose_file over every regional file in data_dir; join LSM; deduplicate."""
    monthly_files = sorted(f for f in data_dir.glob("*_monthly.nc4")
                           if f.name != "globe_monthly.nc4")
    if not monthly_files:
        raise SystemExit(f"no *_monthly.nc4 files found in {data_dir}")
    regions = [f.stem.removesuffix("_monthly") for f in monthly_files]
    print(f"  {len(monthly_files)} region files: {regions}")

    results = {}
    for region, filepath in zip(regions, monthly_files):
        print(f"  diagnosing {region}")
        results[region] = diagnose_file(filepath, region)

    all_cells = pd.concat([r["cells"] for r in results.values()], ignore_index=True)

    # Regional tiles overlap, so collapse to one row per grid cell before mapping.
    # A cell is only ocean if every tile covering it says so, and negative if any
    # tile covering it says so.
    gc = (
        all_cells
        .groupby(["lon", "lat"], sort=False, as_index=False)
        .agg(
            all_nan        =("all_nan",         "all"),
            always_zero    =("always_zero",     "all"),
            has_data       =("has_data",        "any"),
            ever_negative  =("ever_negative",   "any"),
            frac_neg_months=("frac_neg_months", "mean"),
        )
    )
    gc = join_lsm(gc)
    gc["status"] = np.where(gc["all_nan"], "all_nan",
                            np.where(gc["always_zero"], "always_zero", "has_data"))

    # Only the count survives: the per-region min/median/mean are already in each
    # summary, and keeping the raw value arrays for both vintages at once is what
    # would blow the memory budget.
    n_neg_cell_months = int(sum(len(r["neg_vals"]) for r in results.values()))

    # Seasonal counts, normalized by cells with data x timesteps per month so that
    # months with more region-years do not dominate.
    all_seasonal = pd.concat([r["seasonal_neg"] for r in results.values()], ignore_index=True)
    monthly_neg  = all_seasonal.groupby("month")["neg_cells"].sum().reset_index()
    monthly_neg["month_name"] = monthly_neg["month"].map(MONTH_NAMES)
    n_data_cells   = int(gc["has_data"].sum())
    monthly_counts = all_seasonal.groupby("month").size().reset_index(name="n_timesteps")
    monthly_neg    = monthly_neg.merge(monthly_counts, on="month")
    monthly_neg["pct_cells_neg"] = (
        monthly_neg["neg_cells"] / (n_data_cells * monthly_neg["n_timesteps"]) * 100
    )
    # Per-region cells/neg_vals/seasonal_neg have all been folded into gc,
    # n_neg_cell_months and monthly_neg above. Drop them so that only one
    # vintage's worth of raw per-cell frames is ever live.
    summaries = [r["summary"] for r in results.values()]

    return {"summaries": summaries, "gc": gc,
            "n_neg_cell_months": n_neg_cell_months, "monthly_neg": monthly_neg}


# ── Per-file rainfall_flow diagnostics ─────────────────────────────────────────
# rainfall_flow is monthly rainfall accumulated downstream through the TauDEM D8
# network. A NaN means no routed value reached the cell that month. Cells that are
# NaN in *every* month are simply off the network (ocean, or outside the DEM) and
# are expected; the defect this check is looking for is the episodic case -- a cell
# that has a routed value in some months and not others. The flow files live
# alongside the *_monthly.nc4 files with a _monthly_flow suffix; there is no
# separate monthly_flow/ subdirectory.
def diagnose_flow(data_dir):
    """Per-cell and per-month missing-value counts for every flow file in data_dir."""
    flow_files = sorted(data_dir.glob("*_monthly_flow.nc4"))
    if not flow_files:
        print(f"  no *_monthly_flow.nc4 files in {data_dir}")
        return None
    print(f"  {len(flow_files)} flow files: {[f.stem for f in flow_files]}")

    cells_list, time_list, summary = [], [], []

    for fp in flow_files:
        region = fp.stem.removesuffix("_monthly_flow")
        print(f"  diagnosing {region}")

        with xr.open_dataset(fp) as ds:
            flow   = ds["rainfall_flow"]
            tdim   = flow.dims[0]
            n_time = flow.sizes[tdim]
            lon_1d = flow.longitude.values
            lat_1d = flow.latitude.values
            t_vals = pd.DatetimeIndex(flow[tdim].values)
            shape  = (len(lat_1d), len(lon_1d))

            n_missing_acc = np.zeros(shape, dtype=np.int32)
            missing_by_t  = []

            for i in range(0, n_time, TIME_CHUNK):
                chunk   = flow.isel({tdim: slice(i, i + TIME_CHUNK)}).values
                n_t     = chunk.shape[0]
                missing = np.isnan(chunk)

                n_missing_acc += missing.sum(axis=0).astype(np.int32)
                missing_by_t.extend(missing.reshape(n_t, -1).sum(axis=1).tolist())

        LON, LAT = np.meshgrid(lon_1d, lat_1d)
        cells = pd.DataFrame({
            "region":     region,
            "lon":        LON.ravel(),
            "lat":        LAT.ravel(),
            "n_time":     n_time,
            "n_missing":  n_missing_acc.ravel(),
        })
        cells["pct_missing"]    = cells["n_missing"] / n_time * 100
        cells["missing_status"] = np.where(
            cells["n_missing"] == 0, "never",
            np.where(cells["n_missing"] == n_time, "always", "episodic"),
        )
        cells_list.append(cells)

        # Cells missing in every month are missing in every timestep too, so the
        # episodic count per timestep is the total minus that constant. This avoids
        # a second pass over the data just to exclude off-network cells.
        n_always = int((cells["missing_status"] == "always").sum())
        n_onnet  = int(len(cells) - n_always)
        tdf = pd.DataFrame({
            "region":            region,
            "month":             t_vals.month,
            "n_missing":         missing_by_t,
            "n_cells":           len(cells),
            "n_missing_onnet":   np.array(missing_by_t) - n_always,
            "n_cells_onnet":     n_onnet,
        })
        time_list.append(tdf)

        n_cm = len(cells) * n_time
        summary.append({
            "region":                     region,
            "n_time_steps":               n_time,
            "date_min":                   str(t_vals.min().date()),
            "date_max":                   str(t_vals.max().date()),
            "n_cells":                    len(cells),
            "n_cell_months":              n_cm,
            "n_missing_cell_months":      int(cells["n_missing"].sum()),
            "pct_missing_cell_months":    round(float(cells["n_missing"].sum()) / n_cm * 100, 4) if n_cm else 0.0,
            "n_cells_never_missing":      int((cells["missing_status"] == "never").sum()),
            "n_cells_always_missing":     int(n_always),
            "n_cells_episodic_missing":   int((cells["missing_status"] == "episodic").sum()),
            # The headline number: off-network cells excluded, so this is the
            # unexplained missingness the ocean-cell fix is supposed to remove.
            "n_cells_on_network":         n_onnet,
            "pct_cells_on_net_episodic":  round(
                float((cells["missing_status"] == "episodic").sum()) / n_onnet * 100, 4
            ) if n_onnet else 0.0,
        })

    return {
        "summary": pd.DataFrame(summary),
        "cells":   pd.concat(cells_list, ignore_index=True),
        "time":    pd.concat(time_list,  ignore_index=True),
    }


# ── Plot helpers ───────────────────────────────────────────────────────────────
# A vintage-comparison figure is two panels, original on the left and test on the
# right, on shared color and axis scales so the panels can be read against each
# other. The panel list comes from the keys of the `panels` dict passed in, so a
# suite that only concerns one vintage gets a single-panel figure at the same
# per-panel size.
PROJ = ccrs.PlateCarree()


def new_map_panels(vintages, coast_color="gray"):
    fig, axes = plt.subplots(1, len(vintages), figsize=(11 * len(vintages), 7),
                             squeeze=False, subplot_kw={"projection": PROJ})
    axes = axes.ravel()
    for ax, vintage in zip(axes, vintages):
        ax.set_global()
        ax.add_feature(cfeature.COASTLINE, linewidth=0.3, edgecolor=coast_color)
        ax.set_title(f"{vintage} vintage", fontsize=11)
    return fig, dict(zip(vintages, axes))


def save_fig(fig, name, out_dir):
    fig.savefig(out_dir / f"{name}.png", bbox_inches="tight", dpi=150)
    plt.close(fig)
    print(f"  saved {name}.png")


def categorical_map(panels, title, legend_handles, name, out_dir, legend_title=None):
    """panels: {vintage: (lon array, lat array, color array)}."""
    fig, axes = new_map_panels(list(panels))
    for vintage, ax in axes.items():
        lon_vals, lat_vals, colors = panels[vintage]
        ax.scatter(lon_vals, lat_vals, c=colors, s=1, transform=PROJ,
                   linewidths=0, rasterized=True)
    fig.suptitle(title, fontsize=12)
    fig.legend(handles=legend_handles, loc="lower center", ncol=len(legend_handles),
               fontsize=9, frameon=False,
               **({"title": legend_title} if legend_title else {}))
    fig.tight_layout(rect=(0, 0.08, 1, 0.94))
    save_fig(fig, name, out_dir)


def frequency_map(panels, value_col, label, title, name, out_dir):
    """Log-scaled map of a per-cell percentage, on one color scale across panels.

    panels: {vintage: DataFrame with lon, lat, value_col}. A vintage with no
    qualifying cells still gets a panel, labelled as such, so an empty right-hand
    panel reads as "the issue is gone" rather than as a missing figure.
    """
    all_vals = np.concatenate([p[value_col].values for p in panels.values()
                               if len(p)]) if any(len(p) for p in panels.values()) else np.array([])
    if not len(all_vals):
        print(f"  no cells to plot in either vintage -- skipping {name}")
        return

    norm = mcolors.LogNorm(vmin=max(all_vals.min(), 1e-2), vmax=all_vals.max())
    fig, axes = new_map_panels(list(panels))
    sc = None
    for vintage, ax in axes.items():
        df = panels[vintage]
        if not len(df):
            ax.set_title(f"{vintage} vintage -- no qualifying cells", fontsize=11)
            continue
        sc = ax.scatter(df["lon"].values, df["lat"].values, c=df[value_col].values,
                        cmap="YlOrRd", norm=norm, s=1, transform=PROJ,
                        linewidths=0, rasterized=True)
        ax.set_title(f"{vintage} vintage -- {len(df):,} cells", fontsize=11)
    fig.colorbar(sc, ax=list(axes.values()), label=label, shrink=0.6)
    fig.suptitle(title, fontsize=12)
    save_fig(fig, name, out_dir)


def seasonal_bar(panels, value_col, ylabel, title, name, out_dir, color="#d73027"):
    """panels: {vintage: DataFrame with month_name and value_col}. Shared y-axis."""
    vintages = list(panels)
    fig, axes = plt.subplots(1, len(vintages), figsize=(7.5 * len(vintages), 5),
                             squeeze=False, sharey=True)
    axes = axes.ravel()
    for vintage, ax in zip(vintages, axes):
        df = panels[vintage]
        ax.bar(df["month_name"], df[value_col], color=color, edgecolor="white")
        ax.set_xlabel("Month")
        ax.set_title(f"{vintage} vintage", fontsize=11)
    axes[0].set_ylabel(ylabel)
    fig.suptitle(title, fontsize=12)
    fig.tight_layout(rect=(0, 0, 1, 0.92))
    save_fig(fig, name, out_dir)


def stack_by_vintage(frames):
    """Concat {vintage: df} into one frame with a leading `vintage` column."""
    out = pd.concat([df.assign(vintage=v) for v, df in frames.items()], ignore_index=True)
    return out[["vintage"] + [c for c in out.columns if c != "vintage"]]


LSM_COLORS = {
    "sea (<0.2)":            "#2166ac",
    "mostly sea (0.2-0.5)":  "#92c5de",
    "mostly land (0.5-0.8)": "#a1d99b",
    "land (>0.8)":           "#238b45",
}


# ── Suite: ocean masking / missing weather ─────────────────────────────────────
def run_missing_weather(rain, out_dir):
    print("\n=== missing weather ===")

    summary_df = stack_by_vintage({v: pd.DataFrame(rain[v]["summaries"])
                                   for v in VINTAGES})
    print(summary_df.to_string(index=False))
    summary_df.to_csv(out_dir / "missing_weather_summary.csv", index=False)

    # The headline vintage check: how is ocean marked?
    print("\n--- how ocean cells are marked (deduplicated grid cells) ---")
    for v in VINTAGES:
        gc = rain[v]["gc"]
        print(f"{v:9s}  all-NaN: {int(gc['all_nan'].sum()):>10,}   "
              f"always-zero: {int(gc['always_zero'].sum()):>10,}   "
              f"has data: {int(gc['has_data'].sum()):>10,}")

    # Three-way cell status. Blue on the left vs grey on the right is exactly the
    # change the test vintage is supposed to make.
    STATUS_COLORS = {"all_nan": "#bdbdbd", "always_zero": "#2166ac", "has_data": "#4dac26"}
    categorical_map(
        panels={v: (rain[v]["gc"]["lon"].values, rain[v]["gc"]["lat"].values,
                    pd.Series(rain[v]["gc"]["status"]).map(STATUS_COLORS).values)
                for v in VINTAGES},
        title=(
            "Global cell status, all regions combined\n"
            "Grey = no valid value in any month (NaN-masked) | "
            "Blue = 0-filled in every month | Green = has data"
        ),
        legend_handles=[
            mpatches.Patch(color="#bdbdbd", label="all NaN (masked ocean)"),
            mpatches.Patch(color="#2166ac", label="always zero (0-filled ocean)"),
            mpatches.Patch(color="#4dac26", label="has data (land)"),
        ],
        name="cell_status",
        out_dir=out_dir,
        legend_title="Cell status",
    )
    print(f"\nmissing weather outputs in {out_dir}")


# ── Suite: negative rainfall ───────────────────────────────────────────────────
# Original vintage only. The test vintage changed how ocean cells are marked, not
# how rainfall itself is computed, so a two-panel comparison here would be two
# copies of the same land-cell result.
NEG_VINTAGE = "original"


def run_negative_rainfall(rain, out_dir):
    print(f"\n=== negative rainfall ({NEG_VINTAGE} vintage only) ===")

    NEG_COLS = ["region", "n_cells_w_negative", "pct_cells_w_negative",
                "min_neg_value_mm_mo", "median_neg_value_mm_mo", "mean_neg_value_mm_mo",
                "pct_cell_months_neg"]
    neg_summary_df = stack_by_vintage({
        NEG_VINTAGE: pd.DataFrame(rain[NEG_VINTAGE]["summaries"])[NEG_COLS]
    })
    print(neg_summary_df.to_string(index=False))
    neg_summary_df.to_csv(out_dir / "negative_rainfall_summary.csv", index=False)
    print(f"total negative cell-months [{NEG_VINTAGE}]: "
          f"{rain[NEG_VINTAGE]['n_neg_cell_months']:,}")

    df = rain[NEG_VINTAGE]["gc"]
    df = df[df["ever_negative"]].copy()
    df["pct_neg_months"] = df["frac_neg_months"] * 100
    neg_panels = {NEG_VINTAGE: df}

    frequency_map(
        neg_panels, "pct_neg_months",
        label="% of months with negative rainfall (log scale)",
        title=(
            "Cells with negative rainfall, colored by % of months negative"
        ),
        name="negative_frequency",
        out_dir=out_dir,
    )

    seasonal_bar(
        {NEG_VINTAGE: rain[NEG_VINTAGE]["monthly_neg"]}, "pct_cells_neg",
        ylabel="% of cells with data that are negative\n(average across all years, all regions)",
        title=(
            "Seasonal distribution of negative rainfall\n"
        ),
        name="negative_seasonal",
        out_dir=out_dir,
    )
    print(f"\nnegative rainfall outputs in {out_dir}")


# ── Suite: missing rainfall_flow ───────────────────────────────────────────────
def run_missing_flow(flow, out_dir):
    print("\n=== missing rainfall_flow ===")
    have = {v: d for v, d in flow.items() if d is not None}
    if len(have) < len(VINTAGES):
        print(f"  flow files found only for {list(have)} -- no comparison possible, skipping")
        return

    summary_df = stack_by_vintage({v: flow[v]["summary"] for v in VINTAGES})
    print("\n--- prevalence of missing values in rainfall_flow, by region ---")
    print(summary_df.to_string(index=False))
    summary_df.to_csv(out_dir / "missing_flow_summary.csv", index=False)

    # Regional tiles overlap and are not deduplicated here, so the unit throughout
    # this suite is region x cell: a cell covered by two tiles is counted twice.
    for v in VINTAGES:
        cells = flow[v]["cells"]
        tot_cm = int(cells["n_time"].sum())
        tot_ms = int(cells["n_missing"].sum())
        n_epi  = int((cells["missing_status"] == "episodic").sum())
        print(f"\npooled [{v}]: {tot_ms:,} missing cell-months of {tot_cm:,} "
              f"({tot_ms / tot_cm * 100:.4f}%) | {n_epi:,} episodically-missing cells")

    by_month = {}
    for v in VINTAGES:
        tdf = flow[v]["time"]
        bm  = tdf.groupby("month")[["n_missing_onnet", "n_cells_onnet"]].sum().reset_index()
        bm["pct_missing"] = bm["n_missing_onnet"] / bm["n_cells_onnet"] * 100
        bm["month_name"]  = bm["month"].map(MONTH_NAMES)
        by_month[v] = bm
    stack_by_vintage(by_month).to_csv(out_dir / "missing_flow_by_month.csv", index=False)

    MISSING_COLORS = {"never": "#bdbdbd", "episodic": "#d95f02", "always": "#7570b3"}
    categorical_map(
        panels={v: (flow[v]["cells"]["lon"].values, flow[v]["cells"]["lat"].values,
                    flow[v]["cells"]["missing_status"].map(MISSING_COLORS).values)
                for v in VINTAGES},
        title=(
            "rainfall_flow cells by missing-value status (overlapping tiles plotted twice)\n"
            "Purple = missing in every month (off network) | "
            "Orange = missing in some months only (the defect)"
        ),
        legend_handles=[mpatches.Patch(color=c, label=l) for l, c in MISSING_COLORS.items()],
        name="missing_flow_status_map",
        out_dir=out_dir,
        legend_title="Missing status",
    )

    # Restricted to episodic cells: always-missing ocean would otherwise saturate
    # the map at 100% and hide the cells that actually matter.
    frequency_map(
        {v: flow[v]["cells"].query("missing_status == 'episodic'") for v in VINTAGES},
        "pct_missing",
        label="% of months with rainfall_flow missing (log scale)",
        title=(
            "rainfall_flow frequency of missing values, episodic cells only\n"
            "Cells missing in every month (off network) excluded; colored by % of "
            "that cell's months missing"
        ),
        name="missing_flow_frequency_map",
        out_dir=out_dir,
    )
    print(f"\nmissing flow outputs in {out_dir}")


# ── Run ──
# Both vintages are read first and held in memory, then plotted together. The
# figures are paired panels, so there is no way to split this across processes.
out_dirs = {suite: OUT_ROOT / suite
            for suite in ("missing_weather", "negative_rainfall", "missing_flow")}
for d in out_dirs.values():
    d.mkdir(parents=True, exist_ok=True)

rain, flow = {}, {}
for vintage, data_dir in VINTAGE_DIRS.items():
    print(f"\n{'=' * 78}\nvintage: {vintage}  ({data_dir})\n{'=' * 78}")
    # One pass over the rainfall files feeds both rainfall suites.
    rain[vintage] = load_and_diagnose(data_dir)
    flow[vintage] = diagnose_flow(data_dir)

run_missing_weather(rain, out_dirs["missing_weather"])
run_negative_rainfall(rain, out_dirs["negative_rainfall"])
run_missing_flow(flow, out_dirs["missing_flow"])

print("\nDone.")
