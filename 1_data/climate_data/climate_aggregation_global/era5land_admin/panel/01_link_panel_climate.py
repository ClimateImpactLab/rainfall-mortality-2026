#!/usr/bin/env python3
"""
01_link_panel_climate.py

Link ERA5-Land annual climate data to the old global mortality panel.

This script reads:
- old-panel admin-year ids through 2010
- already-aggregated ERA5-Land annual admin climate files
- ERA5-Land admin summary files
- the India 1961 district crosswalk

It writes:
- ERA5-Land to old-panel admin crosswalk
- annual precipitation and temperature file for the old panel
- Stata copy of the annual climate file
- old-panel link review workbook

This file does not aggregate raw rasters or NetCDFs. It starts from the
ERA5-Land admin files already written by the aggregation scripts.

The old panel merge uses only population-weighted annual precipitation and
temperature variables. Wind is added later in 1_data/panel_build.
"""


# ------------------
# Packages
# ------------------

import os
from pathlib import Path

import pandas as pd

from common import add_region_id, atomic_csv, require
from settings import COUNTRIES, OUTPUT_ROOT, PRODUCT, admin_file, country


# -----------------------------
# Paths and variables
# -----------------------------

COMBINED_DIR = OUTPUT_ROOT / PRODUCT / "combined"

# Read and write files in the combined ERA5-Land admin folder.
ANNUAL = COMBINED_DIR / "era5land_admin_annual.csv"
PANEL_IDS = COMBINED_DIR / "global_panel_admin_year_ids.csv"
CROSSWALK = COMBINED_DIR / "era5land_to_global_panel_crosswalk.csv"
PANEL_CLIMATE_CSV = COMBINED_DIR / "era5land_global_panel_annual.csv"
PANEL_CLIMATE_DTA = COMBINED_DIR / "era5land_global_panel_annual.dta"
LINK_REVIEW_XLSX = COMBINED_DIR / "era5land_old_panel_link_review.xlsx"
INDIA_CROSSWALK = Path(
    "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
    "Countries/IND/Shapefile/1961_districts/"
    "districts_1961_final_w_iaa_codes.csv"
)

# These are the old-panel admin-year IDs used for the final merge
PANEL_ID_COLUMNS = ["iso", "adm1_id", "adm2_id", "year"]

# Rename the selected population-weighted ERA5-Land variables to the old-panel names
CLIMATE_RENAME = {
    "prcp_pop_p1": "prcp_poly_1_ERA5LAND",
    "tmean_pop_p1": "tavg_poly_1_ERA5LAND",
    "tmax_pop_p1": "tmax_poly_1_ERA5LAND",
    "prcp_pop_p2": "prcp_poly_2_ERA5LAND",
    "tmean_pop_p2": "tavg_poly_2_ERA5LAND",
    "tmax_pop_p2": "tmax_poly_2_ERA5LAND",
    "prcp_pop_p3": "prcp_poly_3_ERA5LAND",
    "tmean_pop_p3": "tavg_poly_3_ERA5LAND",
    "tmax_pop_p3": "tmax_poly_3_ERA5LAND",
    "prcp_pop_p4": "prcp_poly_4_ERA5LAND",
    "tmean_pop_p4": "tavg_poly_4_ERA5LAND",
    "tmax_pop_p4": "tmax_poly_4_ERA5LAND",
    "prcp_pop_p5": "prcp_poly_5_ERA5LAND",
    "tmean_pop_p5": "tavg_poly_5_ERA5LAND",
    "tmax_pop_p5": "tmax_poly_5_ERA5LAND",
}
CLIMATE_VARIABLES = list(CLIMATE_RENAME.values())


# -----------------------------
# ID matching rules
# -----------------------------

def clean_id(value):
    # Numeric IDs may differ only because one file keeps leading zeros.
    # Text IDs still have to match exactly.
    text = str(value).strip()
    if text == "" or text.lower() == "nan":
        return ""
    if text.isdigit():
        return str(int(text))
    return text.upper()


def panel_lookup(panel, iso=None, adm1=None, adm2=None):
    # `iso`, `adm1`, and `adm2` are old-panel IDs from the country rule.
    selected = panel
    if iso is not None:
        selected = selected.loc[selected["iso"].eq(iso)]
    if adm1 is not None:
        selected = selected.loc[selected["_adm1"].eq(clean_id(adm1))]
    if adm2 is not None:
        selected = selected.loc[selected["_adm2"].eq(clean_id(adm2))]

    # Return original old-panel IDs. _adm1/_adm2 are only comparison IDs.
    selected = selected[["iso", "adm1_id", "adm2_id"]].drop_duplicates()
    require(len(selected) <= 1, f"Ambiguous old-panel match: {selected.to_dict('records')}")
    return None if selected.empty else selected.iloc[0]


def direct_ids(spec, row):
    if spec.code in {"BRA", "FRA", "USA"}:
        # Brazil, France, and the US already carry historical ADM1/ADM2 IDs.
        # Alaska has historical county merges in the old panel.
        if spec.code == "USA" and row["ID_1"] == "02":
            if row["ID_2"] in {"013", "016"}:
                return "USA", "02", "010"
            if row["ID_2"] == "158":
                return "USA", "02", "270"
        return spec.code, row["ID_1"], row["ID_2"]
    if spec.code == "CHL":
        # Chile admin files already contain the old-panel adm1_id / adm2_id.
        return "CHL", row["adm1_id"], row["adm2_id"]
    if spec.code == "CHN":
        # China uses PROVGB and CNTYGB in the old panel.
        return "CHN", row["PROVGB"], row["CNTYGB"]
    if spec.code == "JPN":
        # Japan is prefecture-level in the old panel.
        return "JPN", row["ID_1"], ""
    if spec.code == "MEX":
        # Mexico's GEOID is the old-panel ADM2 identifier.
        return "MEX", None, row["GEOID"]
    if spec.code == "EU":
        # EU regions are matched on NUTS_ID.
        return None, None, row["NUTS_ID"]


def requested_panel_ids(spec, row, india_lookup):
    if spec.code == "IND":
        # India uses the 1961 district crosswalk rather than direct IDs.
        if row["region_id"] in india_lookup.index:
            source = india_lookup.loc[row["region_id"]]
            return (
                ("IND", source["statecode_iaa61"], source["districtcode_iaa61"]),
                str(INDIA_CROSSWALK),
            )

        # IND_330 is labeled DATA NOT AVAILABLE in the old India file. Any
        # other India region missing from the crosswalk is a bad match.
        require(
            row["region_id"] == "IND_330"
            and str(row.get("NAME", "")).strip().upper() == "DATA NOT AVAILABLE",
            f"Unexpected India region missing from historical crosswalk: {row['region_id']}",
        )
        return (
            ("IND", None, "__NO_HISTORICAL_MAPPING__"),
            f"Shapefile unit labeled DATA NOT AVAILABLE, absent from {INDIA_CROSSWALK}",
        )

    if spec.code == "PHL":
        # The Philippines uses new PSGC identifiers and is not in the old panel.
        return (
            ("PHL", row["adm1_psgc"], row["adm3_psgc"]),
            "New Philippines PSGC identifiers, not in old panel",
        )

    if spec.code not in {"BRA", "CHL", "CHN", "EU", "FRA", "JPN", "MEX", "USA"}:
        # These countries have admin climate files but are not mapped into the old panel.
        return (
            (spec.code, None, "__NO_OLD_PANEL_MAPPING__"),
            "Country not mapped into old panel",
        )

    return direct_ids(spec, row), "Historical country cleaning identifier rule"


# -----------------------------
# Build crosswalk
# -----------------------------

def build_crosswalk():
    # Old-panel IDs define the climate rows needed for the through-2010 merge.
    # Keep the original ID strings for output, and make cleaned copies only
    # for matching against climate admin IDs.
    panel = pd.read_csv(
        PANEL_IDS,
        dtype={"iso": "string", "adm1_id": "string", "adm2_id": "string"},
    )
    panel = panel[["iso", "adm1_id", "adm2_id"]].drop_duplicates()
    panel[["iso", "adm1_id", "adm2_id"]] = panel[["iso", "adm1_id", "adm2_id"]].fillna("")
    panel["_adm1"] = panel["adm1_id"].map(clean_id)
    panel["_adm2"] = panel["adm2_id"].map(clean_id)

    # climate_region_id links ERA5-Land India regions to the 1961 district file.
    # India is the only country here where the climate IDs are linked through
    # a separate historical district crosswalk.
    india = pd.read_csv(INDIA_CROSSWALK, dtype=str)
    india["climate_region_id"] = "IND_" + india["unid"].str.zfill(3)
    india_lookup = india.set_index("climate_region_id")

    records = []
    for spec in COUNTRIES.values():
        # Translate each climate admin unit to the IDs used in the old mortality panel.
        # Countries outside the old panel are still written to the crosswalk as
        # not_in_panel, so the audit file shows what was skipped.
        dtype = {column: "string" for column in spec.id_columns}
        admins = pd.read_csv(admin_file(spec), dtype=dtype)
        if "region_id" not in admins:
            admins = add_region_id(admins, spec)

        for row in admins.to_dict("records"):
            # panel_ids = old-panel IDs from the country-specific rule.
            # match = the old-panel unit with those IDs, if it exists.
            panel_ids, mapping_source = requested_panel_ids(spec, row, india_lookup)
            match = panel_lookup(panel, iso=panel_ids[0], adm1=panel_ids[1], adm2=panel_ids[2])
            records.append({
                "climate_country": spec.code,
                "region_id": row["region_id"],
                "panel_iso": "" if match is None else match["iso"],
                "panel_adm1_id": "" if match is None else match["adm1_id"],
                "panel_adm2_id": "" if match is None else match["adm2_id"],
                "match_status": "matched" if match is not None else "not_in_panel",
                "mapping_source": mapping_source,
            })

    crosswalk = pd.DataFrame(records)

    # Only the known Alaska county merges should be many-to-one.
    matched = crosswalk.loc[crosswalk["match_status"].eq("matched")]
    duplicate_target = matched.duplicated(
        ["panel_iso", "panel_adm1_id", "panel_adm2_id"], keep=False
    )
    allowed_alaska_merge = (
        matched["panel_iso"].eq("USA")
        & matched["panel_adm1_id"].eq("02")
        & matched["panel_adm2_id"].eq("010")
    )
    require(
        (~duplicate_target | allowed_alaska_merge).all(),
        "Unexpected multiple climate regions map to one old-panel unit",
    )

    # Country-level count of matched and not-in-panel climate regions.
    counts = (
        crosswalk.groupby(["climate_country", "match_status"])
        .size()
        .unstack(fill_value=0)
        .reset_index()
    )
    atomic_csv(crosswalk, CROSSWALK)
    return crosswalk, counts


# -----------------------------
# Build old-panel climate file
# -----------------------------

def collapse_to_panel_ids(linked):
    # Most climate regions are one-to-one. A few Alaska source counties map to
    # one historical old-panel county and need population-weighted averaging.
    # The LandScan total is only needed for those Alaska many-to-one rows.
    usa_admin = pd.read_csv(admin_file(country("USA")))
    usa_admin["region_id"] = (
        "USA_"
        + usa_admin["ID_0"].astype(str).str.zfill(3)
        + "_"
        + usa_admin["ID_1"].astype(str).str.zfill(2)
        + "_"
        + usa_admin["ID_2"].astype(str).str.zfill(3)
    )
    linked = linked.join(
        usa_admin.set_index("region_id")[["population_total_landscan2011"]],
        on="region_id",
    )
    # Non-Alaska and one-to-one rows do not need reweighting.
    linked["population_total_landscan2011"] = linked["population_total_landscan2011"].fillna(1)

    # Start from one row per final old-panel admin-year, then attach each
    # climate variable below.
    panel_climate = (
        linked.groupby(PANEL_ID_COLUMNS, dropna=False, sort=False)
        .size()
        .rename("_source_rows")
        .reset_index()[PANEL_ID_COLUMNS]
    )
    group_values = [linked[column] for column in PANEL_ID_COLUMNS]

    for variable in CLIMATE_VARIABLES:
        # Average each climate variable separately because missingness can vary
        # across variables within the same admin-year.
        # If one source county is missing this variable, drop its population
        # weight for this variable only.
        valid_weight = linked["population_total_landscan2011"].where(linked[variable].notna(), 0)
        numerator = (linked[variable].fillna(0) * valid_weight).groupby(
            group_values, dropna=False, sort=False
        ).sum()
        denominator = valid_weight.groupby(group_values, dropna=False, sort=False).sum()
        panel_climate[variable] = (numerator / denominator).to_numpy()

    require(
        not panel_climate.duplicated(PANEL_ID_COLUMNS).any(),
        "Panel climate ids are not unique",
    )
    return panel_climate


def climate_coverage(panel_climate):
    # Check which exported old-panel admin-years got ERA5-Land values.
    panel = pd.read_csv(
        PANEL_IDS,
        dtype={"iso": "string", "adm1_id": "string", "adm2_id": "string"},
    ).fillna("")
    panel = panel[PANEL_ID_COLUMNS].drop_duplicates()
    checked = panel.merge(panel_climate, on=PANEL_ID_COLUMNS, how="left", indicator=True)

    # matched_admin_years = old-panel IDs with any linked climate row.
    # complete_climate_admin_years = matched rows with every selected variable.
    summary = (
        checked.assign(
            matched=checked["_merge"].eq("both"),
            climate_complete=checked[CLIMATE_VARIABLES].notna().all(axis=1),
        )
        .groupby("iso")
        .agg(
            panel_admin_years=("year", "size"),
            matched_admin_years=("matched", "sum"),
            complete_climate_admin_years=("climate_complete", "sum"),
        )
        .reset_index()
    )
    summary["unmatched_admin_years"] = (
        summary["panel_admin_years"] - summary["matched_admin_years"]
    )
    # These IDs can be inspected directly if the country summary looks off.
    missing = checked.loc[checked["_merge"].ne("both"), PANEL_ID_COLUMNS]
    return summary, missing


# -----------------------------
# Main
# -----------------------------

def main():
    crosswalk, counts = build_crosswalk()

    # Keep only climate regions that exist in the old panel, then replace
    # climate IDs with the historical panel IDs.
    # The annual file is already admin-aggregated by the ERA5-Land scripts.
    annual = pd.read_csv(ANNUAL, dtype={"region_id": "string"})
    matched = crosswalk.loc[crosswalk["match_status"].eq("matched")].copy()

    # Each annual climate row has one old-panel ID match.
    linked = annual.merge(
        matched,
        on=["climate_country", "region_id"],
        how="inner",
        validate="many_to_one",
    )
    linked = linked.rename(columns={
        "panel_iso": "iso",
        "panel_adm1_id": "adm1_id",
        "panel_adm2_id": "adm2_id",
        **CLIMATE_RENAME,
    })

    # The old-panel merge only carries population-weighted precipitation and
    # temperature variables.
    linked = linked[["region_id", *PANEL_ID_COLUMNS, *CLIMATE_VARIABLES]].copy()

    # Collapse the known Alaska many-to-one county matches to old-panel IDs.
    panel_climate = collapse_to_panel_ids(linked)

    # Compare against the exported old-panel IDs before writing final files.
    coverage, missing = climate_coverage(panel_climate)

    # Write the panel climate file used by the Stata merge.
    panel_climate = panel_climate.sort_values(PANEL_ID_COLUMNS).reset_index(drop=True)
    atomic_csv(panel_climate, PANEL_CLIMATE_CSV)

    # Keep the link review in one workbook instead of several small CSVs.
    with pd.ExcelWriter(LINK_REVIEW_XLSX) as writer:
        crosswalk.to_excel(writer, sheet_name="xwalk", index=False)
        counts.to_excel(writer, sheet_name="counts", index=False)
        coverage.to_excel(writer, sheet_name="cover", index=False)
        missing.to_excel(writer, sheet_name="missing", index=False)

    # Write through a temporary Stata file to avoid a partial .dta.
    temporary = PANEL_CLIMATE_DTA.with_suffix(".tmp.dta")
    panel_climate.to_stata(temporary, write_index=False, version=118)
    os.replace(temporary, PANEL_CLIMATE_DTA)

    print(counts.to_string(index=False))
    print(coverage.to_string(index=False))
    print(f"rows={len(panel_climate)}")
    print(f"wrote={CROSSWALK}")
    print(f"wrote={PANEL_CLIMATE_CSV}")
    print(f"wrote={PANEL_CLIMATE_DTA}")
    print(f"wrote={LINK_REVIEW_XLSX}")


if __name__ == "__main__":
    main()
