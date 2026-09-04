#!/usr/bin/env python3

"""Check ERA5-Land wind around a short list of tropical cyclones.

For each storm in tc_event_spot_check_events.csv, this script reads raw raster
ERA5-Land daily wind_max over the storm window (+/- 1 day). It uses the same
admin weights as the ERA5-Land aggregation code and identifies the admin units
with the largest wind values.

The goal is to check whether the ERA5-Land wind variable picks up the extreme
winds from a small set of major tropical cyclones that occurred within the
countries and years covered by the mortality sample.

I used AI to identify an initial list of prominent tropical cyclones that
should fall within the sample, then checked each of the 12 events against
external sources before adding it to tc_event_spot_check_events.csv.

This provides a quick way to check ERA5-Land wind around known major storms
without bringing in storm-track data.

This is not a TC exposure measure. There are no storm tracks or
distance-to-track measures, and this does not identify all TC-exposed admin
units.

Outputs:
    tc_event_admin_day.csv
    tc_event_top_admins.csv
    tc_event_summary.csv
"""


from importlib import import_module
from pathlib import Path
import sys

import numpy as np
import pandas as pd


# -----------------------------
# Paths
# -----------------------------

REPO = Path("/project/cil/home_dirs/mdefranciosi/repos/rainfall-mortality-2026")
DATA_DIR = Path("/project/cil/gcp/estimation/rainfall-mortality")
ERA5LAND_ADMIN = REPO / "1_data/climate_data/climate_aggregation/scripts/era5land_admin"
AGGREGATION = ERA5LAND_ADMIN / "aggregation_scripts"
EVENT_FILE = DATA_DIR / "external_data/wind_precip_confounding/tc_event_spot_check_events.csv"
OUTPUT_DIR = REPO / "output/data/wind_precip_confounding/tc_event_spot_check"

# Import the ERA5-Land aggregation scripts
sys.path.insert(0, str(ERA5LAND_ADMIN))
sys.path.insert(0, str(AGGREGATION))

# Reuse the existing grid, weights, and wind-reading code
from common import atomic_csv, read_grid, require  # noqa: E402
from settings import climate_file, country  # noqa: E402


# Import the daily precipitation and wind aggregation scripts
daily_aggregation = import_module("02_aggregate_daily")
wind_aggregation = import_module("06_aggregate_wind_exposure")

# Same high-wind cutoff used in the annual wind checks
HIGH_WIND_THRESHOLD = 17.5

# Number of admin units kept for each storm and ranking
TOP_N = 25


# -----------------------------
# Wind during the storm window
# -----------------------------

def weighted_mean(values, matrix):
    # Population- or area-weighted admin mean
    # Missing grid cells are excluded from the denominator
    valid = np.isfinite(values)
    denominator = np.asarray(matrix @ valid.T).T
    numerator = np.asarray(matrix @ np.where(valid, values, 0).T).T
    answer = np.full(numerator.shape, np.nan)
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def weighted_share_above(values, matrix, threshold):
    # Weighted share of the admin unit above the wind cutoff
    valid = np.isfinite(values)
    high = np.where(valid, values > threshold, 0)
    denominator = np.asarray(matrix @ valid.T).T
    numerator = np.asarray(matrix @ high.T).T
    answer = np.full(numerator.shape, np.nan)
    np.divide(numerator, denominator, out=answer, where=denominator > 0)
    return answer


def max_cell_wind(values, matrix):
    # Keep the grid-cell maximum because the strongest storm winds may affect only part of the admin unit
    out = np.full((values.shape[0], matrix.shape[0]), np.nan)
    csr = matrix.tocsr()
    for admin_number in range(csr.shape[0]):
        row = csr.getrow(admin_number)
        positive_columns = row.indices[row.data > 0]
        if len(positive_columns) == 0:
            continue
        admin_values = values[:, positive_columns]
        has_value = np.isfinite(admin_values).any(axis=1)
        out[has_value, admin_number] = np.nanmax(admin_values[has_value], axis=1)
    return out


def aggregate_window_wind(spec, event):
    # Read raw daily wind for the event window
    year = int(event.start_date.year)
    require(event.end_date.year == year, f"{event.event_id} crosses calendar years")

    # Use the same country grid and admin weights as the main aggregation
    grid = read_grid(climate_file(spec, "tp_total", spec.pilot_year))
    admins, flat_indices, matrices = daily_aggregation.load_weights(spec, grid)

    data = None
    try:
        data, wind = wind_aggregation.open_wind_file(spec, year, grid)

        # Use the same fallback as the annual wind aggregation
        flat_indices, matrices = wind_aggregation.apply_wind_fallback(
            spec, year, grid, wind, admins, flat_indices, matrices
        )

        all_dates = daily_aggregation.dates(data, year)
        wanted_dates = pd.date_range(event.start_date, event.end_date, freq="D")
        day_numbers = [int(all_dates.get_loc(date)) for date in wanted_dates]

        # Read only the grid cells used by the admin weights
        raw = daily_aggregation.read_cells(
            wind,
            min(day_numbers),
            max(day_numbers) + 1,
            flat_indices,
        )
    finally:
        if data is not None:
            data.close()

    require(raw.shape[0] == len(wanted_dates), f"Wrong number of days for {event.event_id}")
    require(np.nanmin(raw) >= 0, f"Negative wind in {event.event_id}")
    require(np.nanmax(raw) < 120, f"Implausibly high wind in {event.event_id}")

    # One row per admin-day in the event window
    daily = admins.copy()
    daily["_join_key"] = 1
    dates = pd.DataFrame({"date": wanted_dates, "_join_key": 1})
    daily = dates.merge(daily, on="_join_key", how="left").drop(columns="_join_key")

    # Admin-mean wind, max grid-cell wind, and high-wind shares
    daily["windmax_pop_day"] = weighted_mean(raw, matrices["pop"]).ravel()
    daily["windmax_area_day"] = weighted_mean(raw, matrices["area"]).ravel()
    daily["windcellmax_pop_day"] = max_cell_wind(raw, matrices["pop"]).ravel()
    daily["windcellmax_area_day"] = max_cell_wind(raw, matrices["area"]).ravel()
    daily["windshare_17p5_pop_day"] = weighted_share_above(
        raw, matrices["pop"], HIGH_WIND_THRESHOLD
    ).ravel()
    daily["windshare_17p5_area_day"] = weighted_share_above(
        raw, matrices["area"], HIGH_WIND_THRESHOLD
    ).ravel()
    return daily


def read_window_precip(spec, event):
    # Daily precip is already aggregated to admin units
    year = int(event.start_date.year)
    path = daily_aggregation.output_paths(spec, year)["daily"]
    require(path.is_file(), f"Missing daily precip file: {path}")
    keep_dates = set(
        pd.date_range(event.start_date, event.end_date, freq="D").strftime("%Y-%m-%d")
    )
    precip = pd.read_csv(path, usecols=["date", "region_id", "prcp_pop_p1"])
    precip = precip.loc[precip["date"].isin(keep_dates)].copy()
    precip["date"] = pd.to_datetime(precip["date"])
    precip["prcp_pop_p1"] = pd.to_numeric(precip["prcp_pop_p1"], errors="coerce")
    return precip


# -----------------------------
# Event summaries
# -----------------------------

def date_of_max(frame, value_column, output_column):
    # Date of the largest value for each storm-admin pair
    valid = frame.dropna(subset=[value_column]).copy()
    if valid.empty:
        return (
            frame.loc[:, ["event_id", "region_id"]]
            .drop_duplicates()
            .assign(**{output_column: pd.NaT})
        )

    rows = valid.groupby(["event_id", "region_id"], sort=False)[value_column].idxmax()
    return valid.loc[rows, ["event_id", "region_id", "date"]].rename(
        columns={"date": output_column}
    )


def place_label(row):
    # Admin name columns used by the countries in the storm list
    country_names = {
        "USA": ["NAMELSAD", "NAME"],
        "MEX": ["NAME"],
        "PHL": ["adm3_en"],
        "JPN": ["NAME_1", "NAME"],
        "KOR": ["adm_nam", "NAME"],
        "IND": ["STATE_UT", "NAME", "UNID"],
    }

    values = []
    name_columns = country_names.get(row["country"], [])
    for column in name_columns:
        if column not in row:
            continue
        value = row[column]
        if pd.isna(value):
            continue
        value = str(value).strip()
        if value and value not in values:
            values.append(value)
    return " / ".join(values) if values else row["region_id"]


def summarize_event(admin_day, top_n):
    # Collapse daily rows to one row per storm-admin pair
    # Keep admins that rank highly by admin-mean wind or maximum grid-cell wind

    # Admin names and IDs used by the countries in the event list
    admin_columns = [
        "region_id",
        "NAMELSAD", "NAME", "GEOID",
        "adm3_en", "adm1_id", "adm2_id", "adm3_id",
        "NAME_1", "adm_nam",
        "STATE_UT", "UNID",
        "ID_1", "ID_2",
    ]
    admin_columns = [column for column in admin_columns if column in admin_day.columns]

    grouped = admin_day.groupby(["event_id", "region_id"], sort=False, dropna=False)
    top = grouped.agg(
        # Maximum wind, rain, and high-wind share during the event window
        country=("country", "first"),
        storm_name=("storm_name", "first"),
        event_date=("event_date", "first"),
        known_places=("known_places", "first"),
        max_wind_pop_ms=("windmax_pop_day", "max"),
        max_wind_area_ms=("windmax_area_day", "max"),
        max_cell_wind_pop_ms=("windcellmax_pop_day", "max"),
        max_cell_wind_area_ms=("windcellmax_area_day", "max"),
        max_pop_share_above_17p5=("windshare_17p5_pop_day", "max"),
        max_area_share_above_17p5=("windshare_17p5_area_day", "max"),
        max_prcp_mm=("prcp_pop_p1", "max"),
    ).reset_index()

    # Add admin names and IDs to the summary table
    admin_lookup = admin_day[["event_id"] + admin_columns].drop_duplicates(
        ["event_id", "region_id"]
    )
    top = top.merge(admin_lookup, on=["event_id", "region_id"], how="left")

    # Dates of peak admin-mean wind, peak cell wind, and peak rain
    top = top.merge(
        date_of_max(admin_day, "windmax_pop_day", "date_max_wind_pop"),
        on=["event_id", "region_id"],
        how="left",
    )
    top = top.merge(
        date_of_max(admin_day, "windcellmax_pop_day", "date_max_cell_wind_pop"),
        on=["event_id", "region_id"],
        how="left",
    )
    top = top.merge(
        date_of_max(admin_day, "prcp_pop_p1", "date_max_prcp"),
        on=["event_id", "region_id"],
        how="left",
    )

    top["place_label"] = top.apply(place_label, axis=1)

    # Rank admins by population-weighted mean wind and maximum grid-cell wind
    top = top.sort_values(["event_id", "max_wind_pop_ms"], ascending=[True, False])
    top["rank_by_wind_pop"] = top.groupby("event_id").cumcount() + 1

    cell_order = top.sort_values(
        ["event_id", "max_cell_wind_pop_ms"],
        ascending=[True, False],
    ).index
    top.loc[cell_order, "rank_by_cell_wind_pop"] = (
        top.loc[cell_order].groupby("event_id").cumcount() + 1
    )
    top["rank_by_cell_wind_pop"] = top["rank_by_cell_wind_pop"].astype(int)

    # Keep the top N admins under either wind measure
    keep = (top["rank_by_wind_pop"] <= top_n) | (top["rank_by_cell_wind_pop"] <= top_n)
    return top.loc[keep].sort_values(["event_id", "rank_by_wind_pop", "rank_by_cell_wind_pop"])


def event_summary(top):
    # One summary row per storm
    top_admin_mean = top.sort_values(["event_id", "rank_by_wind_pop"]).drop_duplicates(
        "event_id"
    )
    top_grid_cell = top.sort_values(["event_id", "rank_by_cell_wind_pop"]).drop_duplicates(
        "event_id"
    )

    summary = top_admin_mean[[
        "event_id",
        "country",
        "storm_name",
        "event_date",
        "known_places",
        "region_id",
        "place_label",
        "max_wind_pop_ms",
        "date_max_wind_pop",
        "max_prcp_mm",
    ]].rename(columns={
        "region_id": "top_pop_wind_region_id",
        "place_label": "top_pop_wind_place",
        "max_wind_pop_ms": "top_pop_wind_ms",
        "date_max_wind_pop": "top_pop_wind_date",
        "max_prcp_mm": "top_pop_wind_admin_max_prcp_mm",
    })

    summary = summary.merge(
        top_grid_cell[[
            "event_id",
            "region_id",
            "place_label",
            "max_cell_wind_pop_ms",
            "date_max_cell_wind_pop",
        ]],
        on="event_id",
        how="left",
    ).rename(columns={
        "region_id": "top_cell_wind_region_id",
        "place_label": "top_cell_wind_place",
        "max_cell_wind_pop_ms": "top_cell_wind_ms",
        "date_max_cell_wind_pop": "top_cell_wind_date",
    })

    return summary


# -----------------------------
# Main
# -----------------------------

def main():
    # Read the 12 storm events used for this spot check
    events = pd.read_csv(
        EVENT_FILE,
        parse_dates=["event_date", "start_date", "end_date"],
    )

    required = {"event_id", "country", "storm_name", "event_date", "start_date", "end_date"}
    require(required.issubset(events.columns), "Event file is missing required columns")

    all_admin_day = []
    all_top = []
    for event in events.itertuples(index=False):
        # Read wind and precipitation for each storm window
        spec = country(event.country)
        print(
            f"{event.event_id}: {event.country} "
            f"{event.start_date.date()} to {event.end_date.date()}",
            flush=True,
        )
        wind = aggregate_window_wind(spec, event)
        precip = read_window_precip(spec, event)

        # Add precipitation to the daily wind table
        admin_day = wind.merge(precip, on=["date", "region_id"], how="left")

        # Add storm information to each admin-day
        admin_day.insert(0, "event_id", event.event_id)
        admin_day.insert(1, "country", event.country)
        admin_day.insert(2, "storm_name", event.storm_name)
        admin_day.insert(3, "event_date", event.event_date)
        admin_day.insert(4, "known_places", event.known_places)

        top = summarize_event(admin_day, TOP_N)
        all_admin_day.append(admin_day)
        all_top.append(top)

    admin_day = pd.concat(all_admin_day, ignore_index=True)
    top = pd.concat(all_top, ignore_index=True)
    summary = event_summary(top)

    # Tables used by the R Markdown report (05 Rmd file)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    atomic_csv(admin_day, OUTPUT_DIR / "tc_event_admin_day.csv")
    atomic_csv(top, OUTPUT_DIR / "tc_event_top_admins.csv")
    atomic_csv(summary, OUTPUT_DIR / "tc_event_summary.csv")

    print(f"Wrote {OUTPUT_DIR / 'tc_event_admin_day.csv'}", flush=True)
    print(f"Wrote {OUTPUT_DIR / 'tc_event_top_admins.csv'}", flush=True)
    print(f"Wrote {OUTPUT_DIR / 'tc_event_summary.csv'}", flush=True)


if __name__ == "__main__":
    main()
