#!/usr/bin/env python3
"""
step_01_make_fallback_ids.py

Write the ERA5-Land cell-fallback ID CSVs.

These files list the admin units to check in `step_02_apply_fallback.py`.
The IDs come from missing-climate checks and mortality-panel checks. They are
kept here so the small-cell decisions are visible and reproducible.

Inputs:
- reviewed region_id lists below

Outputs:
- fallback ID CSVs under:

    /project/cil/gcp/estimation/rainfall-mortality/climate_data/
      ERA5-LAND-GLOBAL/cell_fallback_ids/
"""

from pathlib import Path

import pandas as pd

from common import atomic_csv, require
from settings import OUTPUT_ROOT, PRODUCT


OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "cell_fallback_ids"


# -----------------------------
# Reviewed fallback IDs
# -----------------------------

# Brazil has four nearby coastal cases. These units have weights on cells
# masked by the ERA5-Land land mask, with valid cells 0.1 to 0.2 degrees away.
BRA_NEARBY = [
    "BRA_032_05_0395",
    "BRA_032_05_0443",
    "BRA_032_21_4018",
    "BRA_032_25_4971",
]

# Chile uses nearby cells for two Chiloé island communes
CHL_MORTALITY_REQUIRED = [
    ("CHL_10_550", "Quinchao", True),
    ("CHL_10_551", "Puqueldón", True),
]

# India mortality-required units checked for land-mask missingness
IND_MORTALITY_REQUIRED = [
    ("IND_204", "laccadive, minicoy and amindivi islands", True),
    ("IND_221", "diu", True),
]

# Diu is close enough to use a nearby valid ERA5-Land cell. Lakshadweep is not
IND_NEARBY_SUPPORTED = [
    ("IND_221", "Diu", True),
]

# Philippines mortality-required island municipalities found in the missing
# climate checks.
PHL_MORTALITY_REQUIRED = [
    ("PHL_1000000000_1004300000_1004314000", "Laguindingan", True),
    ("PHL_1100000000_1108600000_1108605000", "Sarangani", True),
    ("PHL_1600000000_1606700000_1606704000", "Burgos", True),
    ("PHL_1600000000_1606700000_1606719000", "San Francisco", True),
    ("PHL_1600000000_1606700000_1606721000", "Santa Monica", True),
    ("PHL_1600000000_1606700000_1606723000", "Socorro", True),
    ("PHL_1700000000_1705300000_1705302000", "Agutaya", True),
    ("PHL_1700000000_1705300000_1705308000", "Cagayancillo", True),
    ("PHL_1700000000_1705300000_1705310000", "Cuyo", True),
    ("PHL_1700000000_1705300000_1705313000", "Linapacan", True),
    ("PHL_1700000000_1705300000_1705314000", "Magsaysay", True),
    ("PHL_1700000000_1705300000_1705321000", "Kalayaan", True),
    ("PHL_1700000000_1705900000_1705902000", "Banton", True),
    ("PHL_1700000000_1705900000_1705905000", "Concepcion", True),
    ("PHL_1700000000_1705900000_1705906000", "Corcuera", True),
    ("PHL_1700000000_1705900000_1705910000", "Romblon", True),
    ("PHL_1700000000_1705900000_1705914000", "San Jose", True),
    ("PHL_1900000000_1900700000_1900712000", "Hadji Muhtamad", True),
    ("PHL_1900000000_1906600000_1906603000", "Kalingalan Caluang", True),
    ("PHL_1900000000_1906600000_1906607000", "Old Panamao", True),
    ("PHL_1900000000_1906600000_1906610000", "Pata", True),
    ("PHL_1900000000_1906600000_1906612000", "Siasi", True),
    ("PHL_1900000000_1906600000_1906614000", "Tapul", True),
    ("PHL_1900000000_1906600000_1906615000", "Tongkil", True),
    ("PHL_1900000000_1906600000_1906616000", "Panglima Estino", True),
    ("PHL_1900000000_1906600000_1906617000", "Lugus", True),
    ("PHL_1900000000_1906600000_1906618000", "Pandami", True),
    ("PHL_1900000000_1907000000_1907003000", "Mapun", True),
    ("PHL_1900000000_1907000000_1907004000", "Simunul", True),
    ("PHL_1900000000_1907000000_1907005000", "Sitangkai", True),
    ("PHL_1900000000_1907000000_1907006000", "South Ubian", True),
    ("PHL_1900000000_1907000000_1907008000", "Turtle Islands", True),
    ("PHL_1900000000_1907000000_1907011000", "Sibutu", True),
]

# Philippines units within the 0.5-degree limit after checking population and
# area weights.
PHL_WITHIN_0P5_DEGREES = [
    ("PHL_1000000000_1004300000_1004314000", "Laguindingan", True),
    ("PHL_1100000000_1108600000_1108605000", "Sarangani", True),
    ("PHL_1600000000_1606700000_1606704000", "Burgos", True),
    ("PHL_1600000000_1606700000_1606719000", "San Francisco", True),
    ("PHL_1600000000_1606700000_1606721000", "Santa Monica", True),
    ("PHL_1600000000_1606700000_1606723000", "Socorro", True),
    ("PHL_1700000000_1705300000_1705313000", "Linapacan", True),
    ("PHL_1700000000_1705900000_1705902000", "Banton", True),
    ("PHL_1700000000_1705900000_1705905000", "Concepcion", True),
    ("PHL_1700000000_1705900000_1705906000", "Corcuera", True),
    ("PHL_1700000000_1705900000_1705910000", "Romblon", True),
    ("PHL_1700000000_1705900000_1705914000", "San Jose", True),
    ("PHL_1900000000_1906600000_1906603000", "Kalingalan Caluang", True),
    ("PHL_1900000000_1906600000_1906607000", "Old Panamao", True),
    ("PHL_1900000000_1906600000_1906610000", "Pata", True),
    ("PHL_1900000000_1906600000_1906612000", "Siasi", True),
    ("PHL_1900000000_1906600000_1906614000", "Tapul", True),
    ("PHL_1900000000_1906600000_1906615000", "Tongkil", True),
    ("PHL_1900000000_1906600000_1906616000", "Panglima Estino", True),
    ("PHL_1900000000_1906600000_1906617000", "Lugus", True),
    ("PHL_1900000000_1907000000_1907004000", "Simunul", True),
    ("PHL_1900000000_1907000000_1907006000", "South Ubian", True),
    ("PHL_1900000000_1907000000_1907008000", "Turtle Islands", True),
]

# Nantucket is the only USA unit from the mortality-required list kept here.
# The other USA missing units are overseas territories outside the analysis
# sample.
USA_MORTALITY_REQUIRED = [
    ("USA_244_25_019", "Nantucket County", True),
]


# -----------------------------
# Write files
# -----------------------------

def id_only(region_ids):
    # Brazil only needs the IDs here; names are documented in the detailed check CSV.
    return pd.DataFrame({"region_id": region_ids})


def with_names(rows):
    # Keep names in the CSV when the list came from mortality-panel checks.
    return pd.DataFrame(rows, columns=["region_id", "name", "mortality_relevant"])


def write_csv(name, frame):
    # Duplicate IDs would run the same admin unit twice in step 02.
    require(not frame["region_id"].duplicated().any(), f"Duplicate region_id in {name}")
    path = OUTPUT_DIR / name
    atomic_csv(frame, path)
    print(f"wrote={path} rows={len(frame)}")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Nearby lists are the IDs we actually pass to step 02 when applying the
    # 0.5-degree rule.
    write_csv("bra_global_nearby.csv", id_only(BRA_NEARBY))
    write_csv("ind_nearby_supported.csv", with_names(IND_NEARBY_SUPPORTED))
    write_csv("phl_within_0p5_degrees.csv", with_names(PHL_WITHIN_0P5_DEGREES))

    # Mortality-required lists keep the larger reviewed set, including units
    # that may stay missing because the nearest valid cell is too far away.
    write_csv("chl_mortality_required.csv", with_names(CHL_MORTALITY_REQUIRED))
    write_csv("ind_mortality_required.csv", with_names(IND_MORTALITY_REQUIRED))
    write_csv("phl_mortality_required.csv", with_names(PHL_MORTALITY_REQUIRED))
    write_csv("usa_mortality_required.csv", with_names(USA_MORTALITY_REQUIRED))


if __name__ == "__main__":
    main()
