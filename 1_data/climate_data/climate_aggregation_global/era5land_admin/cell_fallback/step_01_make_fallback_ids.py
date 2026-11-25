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

import argparse
from pathlib import Path

import pandas as pd

from common import atomic_csv, require
from settings import OUTPUT_ROOT, PRODUCT


OUTPUT_DIR = OUTPUT_ROOT / PRODUCT / "cell_fallback_ids"


# -----------------------------
# Reviewed fallback IDs
# -----------------------------

# Canada: this island census division has weights but missing climate.
# It's listed for the distance check, the 0.5-degree limit still applies.
CAN_MORTALITY_REQUIRED = [
    ("CAN_2401", "Communaute maritime des Iles-de-la-Madeleine", True),
]

# Brazil has four nearby coastal cases. These units have weights on cells
# masked by the ERA5-Land land mask, with valid cells 0.1 to 0.2 degrees away.
BRA_NEARBY = [
    "BRA_032_05_0395",
    "BRA_032_05_0443",
    "BRA_032_21_4018",
    "BRA_032_25_4971",
]

# Stable Brazil units with weights on cells masked by ERA5-Land.
BRA_STABLE_MISSING = [
    "BRA_STABLE_260545",  # Fernando de Noronha
    "BRA_STABLE_291610",  # Itaparica
    "BRA_STABLE_291992",  # Madre de Deus
    "BRA_STABLE_431033",  # Imbé
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

# Philippines island municipalities found in the missing-climate checks.
# These now use parent-zone IDs, with the leading zero kept where present.
# BARMM/SGA units are excluded, matching the mortality sample.
PHL_MORTALITY_REQUIRED = [
    ("PHL_1004314000", "Laguindingan", True),
    ("PHL_1108605000", "Sarangani", True),
    ("PHL_1606704000", "Burgos", True),
    ("PHL_1606719000", "San Francisco", True),
    ("PHL_1606721000", "Santa Monica", True),
    ("PHL_1606723000", "Socorro", True),
    ("PHL_1705302000", "Agutaya", True),
    ("PHL_1705308000", "Cagayancillo", True),
    ("PHL_1705310000", "Cuyo", True),
    ("PHL_1705313000", "Linapacan", True),
    ("PHL_1705314000", "Magsaysay", True),
    ("PHL_1705321000", "Kalayaan", True),
    ("PHL_1705902000", "Banton", True),
    ("PHL_1705905000", "Concepcion", True),
    ("PHL_1705906000", "Corcuera", True),
    ("PHL_1705910000", "Romblon", True),
    ("PHL_1705914000", "San Jose", True),
]

# Philippines units within the 0.5-degree limit after checking population and
# area weights.
PHL_WITHIN_0P5_DEGREES = [
    ("PHL_1004314000", "Laguindingan", True),
    ("PHL_1108605000", "Sarangani", True),
    ("PHL_1606704000", "Burgos", True),
    ("PHL_1606719000", "San Francisco", True),
    ("PHL_1606721000", "Santa Monica", True),
    ("PHL_1606723000", "Socorro", True),
    ("PHL_1705313000", "Linapacan", True),
    ("PHL_1705902000", "Banton", True),
    ("PHL_1705905000", "Concepcion", True),
    ("PHL_1705906000", "Corcuera", True),
    ("PHL_1705910000", "Romblon", True),
    ("PHL_1705914000", "San Jose", True),
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
    # Brazil only needs the IDs here, the names are in the detailed check CSV.
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--country", choices=("BRA", "BRA_STABLE", "CAN", "CHL", "IND", "PHL", "USA"),
        help="Write only this country's lists; omit to write all reviewed lists",
    )
    args = parser.parse_args()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # With --country, only that country's lists are rewritten. Required lists
    # can include units too far from a valid cell, step 02 decides on distance.
    outputs = [
        ("CAN", "can_mortality_required.csv", with_names(CAN_MORTALITY_REQUIRED)),
        ("BRA", "bra_global_nearby.csv", id_only(BRA_NEARBY)),
        ("BRA_STABLE", "bra_stable_missing.csv", id_only(BRA_STABLE_MISSING)),
        ("IND", "ind_nearby_supported.csv", with_names(IND_NEARBY_SUPPORTED)),
        ("PHL", "phl_within_0p5_degrees.csv", with_names(PHL_WITHIN_0P5_DEGREES)),
        ("CHL", "chl_mortality_required.csv", with_names(CHL_MORTALITY_REQUIRED)),
        ("IND", "ind_mortality_required.csv", with_names(IND_MORTALITY_REQUIRED)),
        ("PHL", "phl_mortality_required.csv", with_names(PHL_MORTALITY_REQUIRED)),
        ("USA", "usa_mortality_required.csv", with_names(USA_MORTALITY_REQUIRED)),
    ]
    for code, name, frame in outputs:
        if args.country is None or args.country == code:
            write_csv(name, frame)


if __name__ == "__main__":
    main()
