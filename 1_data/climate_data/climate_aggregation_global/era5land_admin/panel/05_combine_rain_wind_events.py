#!/usr/bin/env python3
"""
05_combine_rain_wind_events.py

Combine country-level daily rain-event wind outputs.

This script runs after the country-level jobs from `04_rain_wind_events.py`.
It stacks the country files and writes the combined review tables.

Inputs:
- country-level rain-event wind CSVs from `04_rain_wind_events.py`
- country-year rain/wind summary CSVs from `04_rain_wind_events.py`

Outputs:
- combined event-level rain/wind CSV
- combined country-year summary CSV
- threshold summary and top-event review tables
"""

# ------------------
# Packages
# ------------------


import argparse
from pathlib import Path
import sys

import pandas as pd


# -----------------------------
# Paths and choices
# -----------------------------

CLIMATE_ADMIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CLIMATE_ADMIN))

from settings import OUTPUT_ROOT, PRODUCT  # noqa: E402

# Country-level files from 04 are stored one folder per country.
DEFAULT_INPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined/current_boundaries/daily_rain_event_wind_overlap_by_country"

# Combined event files and review tables are written here.
DEFAULT_OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "combined/current_boundaries/daily_rain_event_wind_overlap"

# Review increasingly heavy rain-event samples.
RAIN_THRESHOLDS_MM = (100, 200, 300)

# Keep enough extreme events for manual review without writing huge tables.
TOP_EVENT_ROWS = 500

# Keep the full available history. Mortality years are selected by the panel merge.
CURRENT_COUNTRIES = pd.read_csv(CLIMATE_ADMIN / "shapefiles_current.csv")["country"].tolist()
FLAG_COLUMNS = ["any_pop_above_17p5_day", "any_pop_above_17p5_pm1day",
                "windmean_ge_17p5_pop_day", "windmean_ge_17p5_pop_pm1day"]


# -----------------------------
# Arguments
# -----------------------------

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    # Optional paths make it easy to rerun the combine step on another folder.
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    return parser.parse_args()


# -----------------------------
# Read country outputs
# -----------------------------

def read_country_files(input_dir, name):
    # Stack the same output file from each country folder written by 04.
    paths = [input_dir / code / name for code in CURRENT_COUNTRIES]
    frames = [pd.read_csv(path, dtype={"region_id": "string"}) for path in paths]
    combined = pd.concat(frames, ignore_index=True)
    for column in FLAG_COLUMNS:
        if column in combined:
            combined[column] = combined[column].astype("boolean")
    return combined


# -----------------------------
# Review tables
# -----------------------------

def summarize_by_threshold(events):
    # Compare increasingly extreme rain-event samples: >=100, >=200, >=300 mm.
    # Same-day wind uses t, pm1day uses the max over t-1, t, t+1.
    rows = []
    for threshold in RAIN_THRESHOLDS_MM:
        sample = events.loc[events["prcp_pop_p1"] >= threshold]

        rows.append({
            "rain_threshold_mm": threshold,

            # Sample size and geographic spread.
            "events": len(sample),
            "countries": sample["climate_country"].nunique(),
            "country_years": sample[["climate_country", "year"]].drop_duplicates().shape[0],
            "admin_units": sample["region_id"].nunique(),

            # Rainfall distribution within this threshold sample.
            "prcp_median": sample["prcp_pop_p1"].median(skipna=True),
            "prcp_p90": sample["prcp_pop_p1"].quantile(0.90),
            "prcp_max": sample["prcp_pop_p1"].max(skipna=True),

            # Wind distribution for the rain date and +/-1 day window.
            "windmax_pop_day_median": sample["windmax_pop_day"].median(skipna=True),
            "windmax_pop_pm1day_median": sample["windmax_pop_pm1day"].median(skipna=True),
            "windmax_pop_pm1day_p90": sample["windmax_pop_pm1day"].quantile(0.90),
            "windmax_pop_pm1day_max": sample["windmax_pop_pm1day"].max(skipna=True),

            # Share of rain events with wind values attached.
            "share_with_same_day_wind": sample["windmax_pop_day"].notna().mean(),
            "share_with_pm1day_wind": sample["windmax_pop_pm1day"].notna().mean(),

            # Any grid-cell exposure above 17.5 m/s vs. admin mean above 17.5 m/s.
            "share_any_pop_above_17p5_day": sample["any_pop_above_17p5_day"].mean(),
            "share_any_pop_above_17p5_pm1day": sample["any_pop_above_17p5_pm1day"].mean(),
            "share_windmean_ge_17p5_day": sample["windmean_ge_17p5_pop_day"].mean(),
            "share_windmean_ge_17p5_pm1day": sample["windmean_ge_17p5_pop_pm1day"].mean(),
        })
    return pd.DataFrame(rows)


def top_tables(events):
    # Largest rain events, regardless of wind.
    top_rain = events.sort_values("prcp_pop_p1", ascending=False).head(TOP_EVENT_ROWS)

    # Heavy-rain events that also show high wind somewhere in the +/-1-day window.
    wet_and_windy = events.loc[events["any_pop_above_17p5_pm1day"]].copy()
    wet_and_windy = wet_and_windy.sort_values(
        ["prcp_pop_p1", "windmax_pop_pm1day"], ascending=[False, False]
    ).head(TOP_EVENT_ROWS)

    # Very high rain without any population-weighted cell above 17.5 m/s.
    high_rain_low_wind = events.loc[
        (events["prcp_pop_p1"] >= 200)
        & events["any_pop_above_17p5_pm1day"].eq(False).fillna(False)
    ].copy()
    high_rain_low_wind = high_rain_low_wind.sort_values(
        "prcp_pop_p1", ascending=False
    ).head(TOP_EVENT_ROWS)
    return top_rain, wet_and_windy, high_rain_low_wind


# -----------------------------
# Main
# -----------------------------

def main():
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # Country outputs already contain same-day and +/-1-day wind measures.
    events = read_country_files(args.input_dir, "daily_extreme_rain_wind_events_ge100mm.csv")
    country_year = read_country_files(
        args.input_dir, "daily_precip_wind_country_year_summary.csv"
    )

    # Build the threshold summary and the event-example tables.
    threshold_summary = summarize_by_threshold(events)
    top_rain, wet_and_windy, high_rain_low_wind = top_tables(events)

    # Combined event file: one row per >=100 mm admin-day.
    events.to_csv(args.output_dir / "daily_extreme_rain_wind_events_ge100mm.csv", index=False)

    # Country-year file: coverage plus simple event counts.
    country_year.to_csv(args.output_dir / "daily_precip_wind_country_year_summary.csv", index=False)

    # Threshold table: compact summary for >=100, >=200, and >=300 mm events.
    threshold_summary.to_csv(
        args.output_dir / "daily_precip_wind_threshold_summary.csv", index=False
    )

    # Event examples for checking the largest rain and rain/wind cases.
    top_rain.to_csv(args.output_dir / "top_daily_rain_events.csv", index=False)
    wet_and_windy.to_csv(args.output_dir / "top_daily_wet_and_windy_events.csv", index=False)
    high_rain_low_wind.to_csv(
        args.output_dir / "top_daily_high_rain_low_wind_events.csv", index=False
    )

    print(f"combined daily rain/wind files: {args.output_dir}")


if __name__ == "__main__":
    main()
