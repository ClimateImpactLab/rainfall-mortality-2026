# Preview figures: ways to turn the USA county flow measures into drought and
# flood variables for a regression, checked against known US events.
#
# Purpose: compare representations of the two annual county measures and see
#   which ones pick out well-known US drought and flood years. No maps: every
#   figure compares measures, representations, or years.
#   Flow is rainfall_flow only (hydro_era5land_admin/flow_common.py).
#     drought measure = flowmean_pop_annual (annual mean of monthly county flow)
#     flood measure   = flowmax_pop_annual  (each cell's max month, then county mean)
#   Uses the PREVIEW run (ERA5-LAND-GLOBAL latitude strips 0-4, 90N to 9.9S).
#
# Inputs:  climate_data/ERA5-LAND-GLOBAL/USA/hydro_preview/annual/
#            era5land_usa_adm2_flow_annual_{1950..2025}.csv   from 02_make_drought_flood.py
#
# Outputs: output/flow_preview/
#            1_levels_scale.png             county averages and spread: why raw levels mislead
#            2_representations_example.png  one county in each representation, 1950-2025
#            3_benchmark_timelines.png      share of counties flagged by year, US and per event
#            4_benchmark_ranks.png          rank of each event year under each representation
#            4_benchmark_ranks.csv          table view of figure 4, with the event-year values
#            5_measure_relationships.png    drought vs flood, pop vs area weights, persistence
#          Summary tables for figures 1, 3 and 5 are printed to the log.
#
# Dependencies: numpy, pandas, matplotlib
#
# Run: sbatch hydro/diagnostics/scripts/vis_flow_preview.sh

import os
import pathlib
import textwrap

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")  # runs headless under SLURM
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, LogNorm, Normalize
from matplotlib.lines import Line2D

home_dir   = pathlib.Path("/Volumes/cil") if pathlib.Path("/Volumes/cil").exists() else pathlib.Path("/project/cil")
script_dir = pathlib.Path(__file__).parents[1]

ANNUAL_DIR = home_dir / "gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND-GLOBAL/USA/hydro_preview/annual"
OUTPUT_DIR = script_dir / "output/flow_preview"
os.makedirs(OUTPUT_DIR, exist_ok=True)

YEARS = list(range(1950, 2026))
DROUGHT = "flowmean_pop_annual"
FLOOD = "flowmax_pop_annual"
MEASURES = ["flowmean_pop_annual", "flowmean_area_annual", "flowmax_pop_annual", "flowmax_area_annual"]
KIND = {DROUGHT: "drought", FLOOD: "flood"}
MEASURE_NAMES = {DROUGHT: "Drought measure (annual mean)", FLOOD: "Flood measure (annual max)"}

# Territories are dropped: no benchmark event is there, and American Samoa is
# south of the preview strips
TERRITORIES = {"60", "66", "69", "72", "78"}

# A county-year is flagged when it is in the county's own driest (drought) or
# wettest (flood) share of years. 10% is the main cutoff, 20% the looser one.
THRESHOLDS = [0.10, 0.20]

# Benchmark events, used only to check whether a representation picks them
# out. Years and states come from the historical record (general knowledge,
# not from data in this repo), so edit or extend as needed. States are where
# each event was centred; a whole-state region also includes counties the
# event missed, which dilutes the signal.
EVENTS = [
    # (label, year, type, states)
    ("1951 Kansas-Missouri flood",           1951, "flood",   ["KS", "MO"]),
    ("1956 Southern Plains drought",         1956, "drought", ["TX", "OK", "KS", "NM"]),
    ("1972 Hurricane Agnes flood",           1972, "flood",   ["PA", "NY", "MD", "VA"]),
    ("1988 Midwest drought",                 1988, "drought", ["IA", "IL", "IN", "MN", "WI"]),
    ("1993 Great Flood, upper Mississippi",  1993, "flood",   ["IA", "MO", "IL", "MN", "WI"]),
    ("2011 Texas-Oklahoma drought",          2011, "drought", ["TX", "OK"]),
    ("2012 central US drought",              2012, "drought", ["IA", "IL", "IN", "MO", "NE", "KS"]),
    ("2019 Missouri River flood",            2019, "flood",   ["NE", "IA", "MO", "SD"]),
]
# State FIPS codes = ID_1 in the flow files (checked against county names in
# the admin summary, e.g. 19_153 Polk County, 48_201 Harris County)
STATE_FIPS = {
    "IA": "19", "IL": "17", "IN": "18", "KS": "20", "MD": "24", "MN": "27", "MO": "29", "NE": "31",
    "NM": "35", "NY": "36", "OK": "40", "PA": "42", "SD": "46", "TX": "48", "VA": "51", "WI": "55",
}

# Example county, in a state with several benchmark events
EXAMPLE_COUNTIES = [
    ("USA_244_29_510", "St. Louis city, MO"),
]

INK, SECONDARY, MUTED = "#0b0b0b", "#52514e", "#898781"
GRID, AXIS, SURFACE = "#e1e0d9", "#c3c2b7", "#fcfcfb"
# Orange = dry, blue = wet (dataviz reference palette slots 2 and 1; the pair
# passes the skill's colorblind checks)
COLORS = {"drought": "#eb6834", "flood": "#2a78d6"}
BLUES = LinearSegmentedColormap.from_list("blues", ["#cde2fb", "#86b6ef", "#3987e5", "#1c5cab", "#0d366b"])
RED_BLUE = LinearSegmentedColormap.from_list("red_blue", ["#e34948", "#f0efec", "#2a78d6"])

plt.rcParams.update({
    "font.size": 10, "axes.edgecolor": AXIS, "axes.linewidth": 0.6,
    "xtick.color": MUTED, "ytick.color": MUTED, "axes.labelcolor": SECONDARY,
})


def tidy(ax):
    # Hairline horizontal grid, no top/right frame
    ax.grid(axis="y", color=GRID, lw=0.5)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)


def save(fig, name):
    out = OUTPUT_DIR / name
    fig.savefig(out, dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  wrote {out}")


def event_counties(states):
    return panel["ID_1"].isin([STATE_FIPS[state] for state in states])


def year_rank(series, year, low_is_extreme):
    # 1 = the most extreme year in the event's direction
    return int(series.rank(ascending=low_is_extreme, method="min").loc[year])


def text_color(cmap, norm, value):
    # White text on dark cells, ink on light cells
    red, green, blue, _ = cmap(norm(value))
    return "white" if 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5 else INK


# -----------------------------
# County-year panel
# -----------------------------

print(f"Reading {len(YEARS)} annual files from {ANNUAL_DIR}")
year_files = [ANNUAL_DIR / f"era5land_usa_adm2_flow_annual_{year}.csv" for year in YEARS]
missing_files = [path.name for path in year_files if not path.exists()]
assert not missing_files, f"missing annual files: {missing_files[:3]}. Run 02_drought_flood_preview.sbatch first."

panel = pd.concat(
    [pd.read_csv(path, usecols=["year", "region_id", "ID_1", *MEASURES], dtype={"region_id": str, "ID_1": str})
     for path in year_files],
    ignore_index=True,
)
assert not panel.duplicated(["region_id", "year"]).any(), "duplicate county-years"
assert sorted(panel["year"].unique()) == YEARS, "annual files do not cover 1950-2025"

panel = panel.loc[~panel["ID_1"].isin(TERRITORIES)]

# Counties are either complete or missing in every year (island land-mask
# gaps). Percentiles need the same years for every county, so drop the empty
# counties and stop if any county is only partly missing.
n_valid = panel.groupby("region_id")[MEASURES].count()
assert n_valid.isin([0, len(YEARS)]).all().all(), "a county is missing only some years"
empty = n_valid.index[(n_valid == 0).all(axis=1)]
panel = panel.loc[~panel["region_id"].isin(empty)].sort_values(["region_id", "year"]).reset_index(drop=True)
assert panel[MEASURES].notna().all().all(), "a county has some measures but not others"
print(f"  {panel['region_id'].nunique():,} counties x {len(YEARS)} years; "
      f"dropped {len(empty)} counties with no flow in any year: {', '.join(empty)}")


# -----------------------------
# Representations
# -----------------------------
#
# For county i and year t, with X a measure and the county's normal taken over
# all 1950-2025 years:
#   level    X_it                                 raw value (mm summed over upstream cells)
#   log_dev  ln X_it - mean over t of ln X_it     same as ln X with county fixed effects
#   z        (X_it - mean_i) / sd_i               standardized anomaly
#   pct      rank of X_it in county i / (n + 1)   empirical percentile, 0-1
#   flag     drought: pct of the drought measure <= cutoff
#            flood:   pct of the flood measure   >= 1 - cutoff
# A fixed normal period (e.g. 1981-2010) is the usual alternative baseline. It
# would shift and rescale z and pct and can change which years are flagged,
# but it does not reorder the years within a county.

assert (panel[MEASURES] > 0).all().all(), "log_dev needs positive flow, but some county-years are <= 0"

by_county = panel.groupby("region_id")
for column in MEASURES:
    log_value = np.log(panel[column])
    panel[f"{column}_log_dev"] = log_value - log_value.groupby(panel["region_id"]).transform("mean")
    panel[f"{column}_z"] = (panel[column] - by_county[column].transform("mean")) / by_county[column].transform("std")
    # Every county has all years (checked above), so n is the same everywhere
    panel[f"{column}_pct"] = by_county[column].rank(method="average") / (len(YEARS) + 1)

for cutoff in THRESHOLDS:
    tag = round(cutoff * 100)
    panel[f"drought_flag{tag}"] = panel[f"{DROUGHT}_pct"] <= cutoff
    panel[f"flood_flag{tag}"] = panel[f"{FLOOD}_pct"] >= 1 - cutoff

# Every county has the same number of flagged years, so this is the share of
# counties flagged in a year if flagged years were spread evenly over time
EVEN_SHARE = panel["drought_flag10"].mean()


# -----------------------------
# Benchmark events under each representation
# -----------------------------
#
# For each event, average each representation over the event states' counties
# (unweighted) in every year, then rank the event year among all years. A
# representation that tracks real droughts and floods should put the event
# year at or near rank 1.

RANK_COLUMN = f"rank_among_{len(YEARS)}_years"
rank_rows = []
for label, year, kind, states in EVENTS:
    region = panel.loc[event_counties(states)]
    by_year = region.groupby("year")
    measure, other = (DROUGHT, FLOOD) if kind == "drought" else (FLOOD, DROUGHT)
    low = kind == "drought"   # droughts are the low tail, floods the high tail
    representations = {
        "Level (raw)": (by_year[measure].mean(), low),
        "Log deviation": (by_year[f"{measure}_log_dev"].mean(), low),
        "z-score": (by_year[f"{measure}_z"].mean(), low),
        "Percentile": (by_year[f"{measure}_pct"].mean(), low),
        "Share flagged, 10% cutoff": (by_year[f"{kind}_flag10"].mean(), False),
        "Share flagged, 20% cutoff": (by_year[f"{kind}_flag20"].mean(), False),
        # Does the other measure pick out the same year? (e.g. the annual mean for a flood)
        "z-score of the other measure": (by_year[f"{other}_z"].mean(), low),
    }
    for name, (series, low_is_extreme) in representations.items():
        rank_rows.append({
            "event": label, "year": year, "type": kind, "states": " ".join(states),
            "counties": region["region_id"].nunique(), "representation": name,
            "event_year_value": series.loc[year], RANK_COLUMN: year_rank(series, year, low_is_extreme),
        })
ranks = pd.DataFrame(rank_rows)
ranks.to_csv(OUTPUT_DIR / "4_benchmark_ranks.csv", index=False, float_format="%.6g")
print(f"  wrote {OUTPUT_DIR / '4_benchmark_ranks.csv'}")


# -----------------------------
# Figure 1: why raw levels mislead
# -----------------------------
#
# Flow sums water over the whole upstream area, so a county on a big river has
# a far larger level than a headwater county. When the year-to-year spread
# grows with the level, raw deviations in a pooled regression are dominated by
# big-river counties, even with county fixed effects.

normals = panel.groupby("region_id")[[DROUGHT, FLOOD]].agg(["mean", "std"])
averages = normals.xs("mean", axis=1, level=1)

fig, axes = plt.subplots(1, 3, figsize=(16, 4.8))
fig.subplots_adjust(wspace=0.28, top=0.80)

ax = axes[0]
bins = np.logspace(np.log10(averages.min().min()), np.log10(averages.max().max()), 60)
for column in (DROUGHT, FLOOD):
    ax.hist(averages[column], bins=bins, histtype="step", lw=2, color=COLORS[KIND[column]], label=MEASURE_NAMES[column])
ax.set_xscale("log")
ax.set_xlabel("county 1950-2025 average (log scale)")
ax.set_ylabel("counties")
ax.set_title("(a) County averages", loc="left", color=INK)
ax.legend(frameon=False, fontsize=9, loc="upper right")
tidy(ax)

for ax, column, letter in ((axes[1], DROUGHT, "b"), (axes[2], FLOOD, "c")):
    mean, sd = normals[(column, "mean")], normals[(column, "std")]
    ax.scatter(mean, sd, s=5, color=COLORS[KIND[column]], alpha=0.35, linewidths=0)
    # Reference line: sd proportional to the average, at the median county ratio
    cv = (sd / mean).median()
    line_x = np.array([mean.min(), mean.max()])
    ax.plot(line_x, cv * line_x, color=SECONDARY, lw=1)
    ax.annotate(f"sd = {cv:.2f} x average\n(median county)", (line_x[1], cv * line_x[1]),
                xytext=(-4, -30), textcoords="offset points", ha="right", fontsize=8.5, color=SECONDARY)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("county average (log scale)")
    ax.set_ylabel("county sd across years (log scale)")
    ax.set_title(f"({letter}) {KIND[column].capitalize()} measure: spread vs average", loc="left", color=INK)
    tidy(ax)

quantiles = averages.quantile([0.01, 0.5, 0.99])
fig.suptitle("Raw levels: county averages and year-to-year spread", x=0.125, ha="left", color=INK, fontsize=14, y=0.98)
fig.text(0.125, 0.905,
         f"Drought measure county averages: 1st percentile {quantiles.at[0.01, DROUGHT]:,.0f}, "
         f"median {quantiles.at[0.5, DROUGHT]:,.0f}, 99th percentile {quantiles.at[0.99, DROUGHT]:,.0f} "
         "(mm summed over upstream cells). Population weights, preview run.",
         fontsize=9, color=SECONDARY)
save(fig, "1_levels_scale.png")
print("  county 1950-2025 averages, quantiles:")
print(quantiles.round(1).to_string())
print("  median county sd / average:", (normals.xs("std", axis=1, level=1) / averages).median().round(3).to_dict())


# -----------------------------
# Figure 2: one county in each representation
# -----------------------------

ROWS = [
    ("", "Level (raw)\nmm summed upstream"),
    ("_log_dev", "Log deviation\nfrom county average"),
    ("_z", "z-score"),
    ("_pct", "Percentile\nwithin county"),
]

# squeeze=False keeps axes 2-D (row, county) even with one county
fig, axes = plt.subplots(len(ROWS), len(EXAMPLE_COUNTIES), figsize=(10, 11.5), sharex=True, squeeze=False)
fig.subplots_adjust(hspace=0.22, wspace=0.16, top=0.85)
for col, (region_id, name) in enumerate(EXAMPLE_COUNTIES):
    series = panel.loc[panel["region_id"] == region_id].set_index("year")
    assert len(series) == len(YEARS), f"{region_id} does not have all years"
    state = series["ID_1"].iloc[0]
    county_events = [(year, kind) for _, year, kind, states in EVENTS
                     if state in [STATE_FIPS[code] for code in states]]

    for row, (suffix, row_name) in enumerate(ROWS):
        ax = axes[row, col]
        for year, _ in county_events:
            ax.axvline(year, color=GRID, lw=1, zorder=0)
        for column in (DROUGHT, FLOOD):
            ax.plot(series.index, series[f"{column}{suffix}"], color=COLORS[KIND[column]], lw=1.6)
        if col == 0:
            ax.set_ylabel(row_name)
        tidy(ax)

    # Year-only labels on the lines (full names would collide); the event
    # types go in the caption under the county name
    axes[0, col].set_title(name, loc="left", color=INK, fontsize=12, pad=30)
    axes[0, col].text(0, 1.10, "Benchmark events: " + ", ".join(f"{year} {kind}" for year, kind in county_events),
                      transform=axes[0, col].transAxes, fontsize=8.5, color=SECONDARY, va="bottom")
    for year, _ in county_events:
        axes[0, col].annotate(str(year), (year, 1.0), xycoords=("data", "axes fraction"),
                              xytext=(0, 3), textcoords="offset points", ha="center", va="bottom",
                              fontsize=7.5, color=SECONDARY)

    # Percentile row: the 10% cutoffs and the flagged years
    ax = axes[-1, col]
    for level in (THRESHOLDS[0], 1 - THRESHOLDS[0]):
        ax.axhline(level, color=AXIS, lw=0.8)
    for column, flag in ((DROUGHT, "drought_flag10"), (FLOOD, "flood_flag10")):
        flagged = series.loc[series[flag]]
        ax.scatter(flagged.index, flagged[f"{column}_pct"], s=36, color=COLORS[KIND[column]],
                   edgecolors=SURFACE, linewidths=1.5, zorder=3)
    # A little headroom so dots near 0 and 1 are not clipped
    ax.set_ylim(-0.04, 1.04)
    ax.set_xlabel("year")

# Rows below the first are scale-free, so all example counties share one y-range
for row in range(1, len(ROWS)):
    low = min(axes[row, col].get_ylim()[0] for col in range(len(EXAMPLE_COUNTIES)))
    high = max(axes[row, col].get_ylim()[1] for col in range(len(EXAMPLE_COUNTIES)))
    for col in range(len(EXAMPLE_COUNTIES)):
        axes[row, col].set_ylim(low, high)

fig.suptitle("The same county-years in four representations", x=0.125, ha="left", color=INK, fontsize=14, y=0.985)
fig.text(0.125, 0.958,
         "Dots: years in the county's driest or wettest 10%.\n"
         "Vertical lines: benchmark events in the county's state.",
         fontsize=9, color=SECONDARY, va="top")
legend_handles = [
    Line2D([], [], color=COLORS["drought"], lw=2),
    Line2D([], [], color=COLORS["flood"], lw=2),
]
fig.legend(legend_handles, [MEASURE_NAMES[DROUGHT], MEASURE_NAMES[FLOOD]], loc="upper left",
           bbox_to_anchor=(0.12, 0.925), ncol=2, frameon=False, fontsize=9)
save(fig, "2_representations_example.png")


# -----------------------------
# Figure 3: share of counties flagged, by year
# -----------------------------

fig, axes = plt.subplots(3, 3, figsize=(16, 10.5), sharex=True, sharey=True)
fig.subplots_adjust(hspace=0.36, wspace=0.08, top=0.87)

national = panel.groupby("year")[["drought_flag10", "flood_flag10"]].mean()
ax = axes.flat[0]
ax.axhline(EVEN_SHARE, color=AXIS, lw=0.8)
for kind in ("drought", "flood"):
    ax.plot(national.index, national[f"{kind}_flag10"], color=COLORS[kind], lw=1.6)
ax.set_title("All counties, 50 states + DC", loc="left", color=INK, fontsize=11, pad=16)
ax.text(0, 1.02, f"{panel['region_id'].nunique():,} counties", transform=ax.transAxes,
        fontsize=8.5, color=SECONDARY, va="bottom")
ax.set_ylabel("share of counties flagged")
tidy(ax)

for ax, (label, year, kind, states) in zip(axes.flat[1:], EVENTS):
    region = panel.loc[event_counties(states)]
    share = region.groupby("year")[f"{kind}_flag10"].mean()
    rank = year_rank(share, year, low_is_extreme=False)
    ax.axvline(year, color=GRID, lw=1, zorder=0)
    ax.axhline(EVEN_SHARE, color=AXIS, lw=0.8)
    ax.plot(share.index, share.to_numpy(), color=COLORS[kind], lw=1.6)
    ax.scatter([year], [share.loc[year]], s=40, color=COLORS[kind], edgecolors=SURFACE, linewidths=1.5, zorder=3)
    # The event-year result goes under the title, so it never sits on the data
    ax.set_title(label, loc="left", color=INK, fontsize=11, pad=16)
    ax.text(0, 1.02,
            f"{', '.join(states)} ({region['region_id'].nunique():,} counties). "
            f"{year}: {share.loc[year]:.0%} flagged, rank {rank} of {len(YEARS)}",
            transform=ax.transAxes, fontsize=8.5, color=SECONDARY, va="bottom")
    tidy(ax)

for ax in axes[-1]:
    ax.set_xlabel("year")
for ax in axes[:, 0]:
    ax.set_ylabel("share of counties flagged")

fig.suptitle("Share of counties in their driest or wettest 10% of years", x=0.125, ha="left",
             color=INK, fontsize=14, y=0.985)
fig.text(0.125, 0.952,
         "Drought: drought measure in the county's lowest 10% of 1950-2025. Flood: flood measure in its top 10%. "
         "Gray line: the share expected if flagged years were spread evenly. Benchmark panels show the event's type only.",
         fontsize=9, color=SECONDARY)
legend_handles = [Line2D([], [], color=COLORS["drought"], lw=2), Line2D([], [], color=COLORS["flood"], lw=2)]
fig.legend(legend_handles, ["Drought flag (driest 10%)", "Flood flag (wettest 10%)"], loc="upper left",
           bbox_to_anchor=(0.12, 0.945), ncol=2, frameon=False, fontsize=9)
save(fig, "3_benchmark_timelines.png")

# Table view of the national panel: the years with the most counties flagged
for kind in ("drought", "flood"):
    top = national[f"{kind}_flag10"].sort_values(ascending=False).head(8)
    print(f"  years with the largest share of counties {kind}-flagged (10%): "
          + ", ".join(f"{year} {share:.0%}" for year, share in top.items()))


# -----------------------------
# Figure 4: benchmark rank under each representation
# -----------------------------

event_order = [label for label, *_ in EVENTS]
representation_order = list(dict.fromkeys(ranks["representation"]))
grid = ranks.pivot(index="event", columns="representation", values=RANK_COLUMN).loc[event_order, representation_order]

rank_cmap = BLUES.reversed()             # dark = rank 1, the most extreme year
rank_norm = LogNorm(1, len(YEARS))       # log scale spreads out the top ranks

fig, ax = plt.subplots(figsize=(13, 6.4))
fig.subplots_adjust(top=0.80)
ax.imshow(grid.to_numpy(), cmap=rank_cmap, norm=rank_norm, aspect="auto")
for i in range(grid.shape[0]):
    for j in range(grid.shape[1]):
        value = grid.iat[i, j]
        ax.text(j, i, str(value), ha="center", va="center", fontsize=10, color=text_color(rank_cmap, rank_norm, value))
ax.set_xticks(range(len(representation_order)))
ax.set_xticklabels([textwrap.fill(name, 16) for name in representation_order], fontsize=9, color=SECONDARY)
ax.set_yticks(range(len(event_order)))
ax.set_yticklabels(event_order, fontsize=9.5, color=SECONDARY)
ax.xaxis.tick_top()
# White gaps between cells instead of borders
ax.set_xticks(np.arange(-0.5, len(representation_order)), minor=True)
ax.set_yticks(np.arange(-0.5, len(event_order)), minor=True)
ax.grid(which="minor", color="white", lw=2)
ax.tick_params(which="both", length=0)
for spine in ax.spines.values():
    spine.set_visible(False)
bar = fig.colorbar(plt.cm.ScalarMappable(norm=rank_norm, cmap=rank_cmap), ax=ax, fraction=0.03, pad=0.02,
                   ticks=[1, 2, 5, 10, 20, 50])
bar.ax.set_yticklabels(["1", "2", "5", "10", "20", "50"])
bar.set_label(f"rank of the event year among {len(YEARS)} (1 = most extreme, log scale)", color=SECONDARY)
bar.outline.set_linewidth(0.4)
fig.suptitle("Where each benchmark year ranks under each representation", x=0.02, ha="left",
             color=INK, fontsize=14, y=0.985)
fig.text(0.02, 0.925, "Each cell: the event states' counties averaged by year, then the event year ranked "
         "(droughts: lowest first; floods: highest first). Table: 4_benchmark_ranks.csv",
         fontsize=9, color=SECONDARY)
save(fig, "4_benchmark_ranks.png")
print("  benchmark ranks (1 = most extreme year):")
print(grid.to_string())


# -----------------------------
# Figure 5: how the measures relate
# -----------------------------
#
# (a) Do the drought and flood measures move together? If they are close to
#     one variable, putting both in a regression mostly splits one effect.
# (b) Within-county correlation of all four measures, so the choice of
#     population vs area weights can be judged.
# (c) Persistence: correlation of each year with earlier years, which bears on
#     using lags or multi-year averages.

fig, axes = plt.subplots(1, 3, figsize=(18, 5.2), gridspec_kw={"width_ratios": [1.15, 1, 1]})
fig.subplots_adjust(wspace=0.45, top=0.80)

ax = axes[0]
z_drought, z_flood = panel[f"{DROUGHT}_z"], panel[f"{FLOOD}_z"]
hexes = ax.hexbin(z_drought, z_flood, gridsize=55, cmap=BLUES, bins="log", mincnt=1, linewidths=0)
ax.axhline(0, color=AXIS, lw=0.6)
ax.axvline(0, color=AXIS, lw=0.6)
correlation = z_drought.corr(z_flood)
both = (panel["drought_flag10"] & panel["flood_flag10"]).mean()
ax.text(0.03, 0.97, f"r = {correlation:.2f}\nflagged dry and wet in the same year:\n{both:.2%} of county-years",
        transform=ax.transAxes, va="top", fontsize=9, color=SECONDARY,
        bbox=dict(facecolor="white", edgecolor="none", alpha=0.85, pad=2))
ax.set_xlabel("drought measure z-score (annual mean)")
ax.set_ylabel("flood measure z-score (annual max)")
ax.set_title("(a) Drought vs flood measure", loc="left", color=INK)
bar = fig.colorbar(hexes, ax=ax, fraction=0.05, pad=0.02)
bar.set_label("county-years per hexagon (log scale)", color=SECONDARY)
bar.outline.set_linewidth(0.4)
for side in ("top", "right"):
    ax.spines[side].set_visible(False)

ax = axes[1]
short_names = {"flowmean_pop_annual": "mean, pop", "flowmean_area_annual": "mean, area",
               "flowmax_pop_annual": "max, pop", "flowmax_area_annual": "max, area"}
correlations = panel[[f"{column}_z" for column in MEASURES]].corr()
correlation_norm = Normalize(-1, 1)
ax.imshow(correlations.to_numpy(), cmap=RED_BLUE, norm=correlation_norm)
for i in range(len(MEASURES)):
    for j in range(len(MEASURES)):
        value = correlations.iat[i, j]
        ax.text(j, i, f"{value:.2f}", ha="center", va="center", fontsize=10,
                color=text_color(RED_BLUE, correlation_norm, value))
ax.set_xticks(range(len(MEASURES)))
ax.set_xticklabels([short_names[column] for column in MEASURES], fontsize=9, color=SECONDARY)
ax.set_yticks(range(len(MEASURES)))
ax.set_yticklabels([short_names[column] for column in MEASURES], fontsize=9, color=SECONDARY)
ax.set_xticks(np.arange(-0.5, len(MEASURES)), minor=True)
ax.set_yticks(np.arange(-0.5, len(MEASURES)), minor=True)
ax.grid(which="minor", color="white", lw=2)
ax.tick_params(which="both", length=0)
for spine in ax.spines.values():
    spine.set_visible(False)
ax.set_title("(b) Correlation of z-scores", loc="left", color=INK)

ax = axes[2]
LAGS = list(range(1, 6))
persistence = {}
for column in (DROUGHT, FLOOD):
    z = panel[f"{column}_z"]
    by_region = panel.groupby("region_id")[f"{column}_z"]
    persistence[column] = [z.corr(by_region.shift(lag)) for lag in LAGS]
    ax.plot(LAGS, persistence[column], color=COLORS[KIND[column]], lw=2, marker="o", ms=7,
            mec=SURFACE, mew=1.5, label=MEASURE_NAMES[column])
ax.axhline(0, color=AXIS, lw=0.8)
ax.set_xticks(LAGS)
ax.set_xlabel("lag (years)")
ax.set_ylabel("correlation of z with its own lag")
ax.set_title("(c) Persistence across years", loc="left", color=INK)
ax.legend(frameon=False, fontsize=9)
tidy(ax)

fig.suptitle("How the measures relate within counties", x=0.125, ha="left", color=INK, fontsize=14, y=0.98)
fig.text(0.125, 0.905, "All county-years pooled; z-scores are within county, so county differences in level are removed.",
         fontsize=9, color=SECONDARY)
save(fig, "5_measure_relationships.png")

print("  within-county z-score correlations:")
print(correlations.rename(index=lambda name: name[:-2], columns=lambda name: name[:-2]).round(3).to_string())
print("  drought x flood flags (10%), share of county-years:")
print(pd.crosstab(panel["drought_flag10"], panel["flood_flag10"], normalize=True).round(4).to_string())
for column, values in persistence.items():
    print(f"  persistence of {column} z, lags {LAGS[0]}-{LAGS[-1]}: " + ", ".join(f"{value:.3f}" for value in values))

print("Done.")
