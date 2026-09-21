#!/usr/bin/env python3
"""
check_india_id_mapping.py

Check India shapefile-to-mortality identifiers.

This script checks the historical mortality mapping for two India climate
units. The current shapefile identifies districts by `UNID`. The historical
crosswalk supplies the 1961 state and district codes used by the mortality data.

Inputs:
- current India shapefile
- current India admin summary
- historical 1961 India district crosswalk
- retained mortality-ID export
- legacy segment-weight header

Outputs:
- evidence CSV with one row per checked unit

No climate, mortality, or weight file is changed.
"""

from difflib import SequenceMatcher
from pathlib import Path
import re

import geopandas as gpd
import pandas as pd

from common import atomic_csv, require
from settings import OUTPUT_ROOT, admin_file, country


HISTORICAL_CROSSWALK = Path(
    "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
    "Countries/IND/Shapefile/1961_districts/"
    "districts_1961_final_w_iaa_codes.csv"
)
MORTALITY_ID_EXPORT = Path(
    "/home/mdefranciosi/global_mortality_ids_chl_chn_eu_ind_usa.csv"
)
LEGACY_SEGMENT_WEIGHTS = Path(
    "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
    "Countries/IND/Shapefile/1961_districts/segment_weights/"
    "1961_districts_final_GMFD_grid_segment_weights_area_pop.csv"
)
OUTPUT = (
    OUTPUT_ROOT / "ERA5-LAND/missing_admin_mortality_check/"
    "india_admin_mortality_crosswalk.csv"
)
TARGET_UNIDS = [204, 221]


# -----------------------------
# Name Matching
# -----------------------------

def normalized(value):
    return re.sub(r"[^a-z0-9]", "", str(value).lower())


def names_compatible(left, right):
    a = normalized(left)
    b = normalized(right)
    if not a or not b:
        return False
    return a in b or b in a or SequenceMatcher(None, a, b).ratio() >= 0.72


# -----------------------------
# Main
# -----------------------------

def main():
    spec = country("IND")
    require(HISTORICAL_CROSSWALK.is_file(), f"Missing crosswalk: {HISTORICAL_CROSSWALK}")
    require(MORTALITY_ID_EXPORT.is_file(), f"Missing mortality export: {MORTALITY_ID_EXPORT}")
    require(LEGACY_SEGMENT_WEIGHTS.is_file(), f"Missing legacy weights: {LEGACY_SEGMENT_WEIGHTS}")

    shape_ids = gpd.read_file(
        spec.shapefile,
        columns=["UNID", "STATE_UT", "NAME"],
        engine="pyogrio",
    ).drop(columns="geometry")
    shape_ids["UNID"] = pd.to_numeric(shape_ids.UNID, errors="raise").astype(int)
    require(
        not shape_ids.loc[shape_ids.UNID.isin(TARGET_UNIDS), "UNID"].duplicated().any(),
        "Target UNID values are duplicated in the shapefile",
    )

    historical = pd.read_csv(HISTORICAL_CROSSWALK)
    historical["unid"] = pd.to_numeric(historical.unid, errors="raise").astype(int)
    current_admin = pd.read_csv(admin_file(spec))
    current_admin["UNID"] = pd.to_numeric(current_admin.UNID, errors="raise").astype(int)
    mortality = pd.read_csv(MORTALITY_ID_EXPORT, dtype=str)
    mortality = mortality.loc[mortality.iso == "IND"].copy()

    legacy_header = pd.read_csv(LEGACY_SEGMENT_WEIGHTS, nrows=0).columns.tolist()
    require("UNID" in legacy_header, "Legacy segment weights do not contain UNID")

    records = []
    for unid in TARGET_UNIDS:
        # Each target unit must appear once in each source
        shape_row = shape_ids.loc[shape_ids.UNID == unid]
        cross = historical.loc[historical.unid == unid]
        admin = current_admin.loc[current_admin.UNID == unid]
        require(
            len(shape_row) == len(cross) == len(admin) == 1,
            f"Incomplete source match for UNID={unid}",
        )

        shape_row = shape_row.iloc[0]
        cross = cross.iloc[0]
        admin = admin.iloc[0]
        state_code = str(int(cross.statecode_iaa61))
        district_code = str(int(cross.districtcode_iaa61))
        mortality_rows = mortality.loc[
            (mortality.adm1_id == state_code)
            & (mortality.adm2_id == district_code)
        ]
        require(
            not mortality_rows.empty,
            f"No mortality rows for UNID={unid} historical codes",
        )

        # Names do not need to be byte-identical across sources.
        # They should still point to the same state and district.
        shape_match = (
            names_compatible(shape_row.STATE_UT, cross.state)
            and names_compatible(shape_row.NAME, cross.district)
            and names_compatible(admin.STATE_UT, cross.state)
            and names_compatible(admin.NAME, cross.district)
        )
        mortality_match = (
            mortality_rows.adm1.map(
                lambda value: names_compatible(value, cross.state)
            ).all()
            and mortality_rows.adm2.map(
                lambda value: names_compatible(value, cross.district)
            ).all()
        )

        records.append(
            {
                "climate_region_id": f"IND_{unid:03d}",
                "boundary_UNID": unid,
                "boundary_state_name": shape_row.STATE_UT,
                "boundary_district_name": shape_row.NAME,
                "historical_adm1_id": state_code,
                "historical_adm2_id": district_code,
                "historical_state_name": cross.state,
                "historical_district_name": cross.district,
                "mortality_adm1_id": state_code,
                "mortality_adm2_id": district_code,
                "mortality_state_names": ";".join(sorted(mortality_rows.adm1.unique())),
                "mortality_district_names": ";".join(sorted(mortality_rows.adm2.unique())),
                "mortality_rows": len(mortality_rows),
                "mortality_years": ";".join(
                    map(str, sorted(pd.to_numeric(mortality_rows.year).unique()))
                ),
                "mapping_source": str(HISTORICAL_CROSSWALK),
                "boundary_source": str(spec.shapefile),
                "current_admin_summary": str(admin_file(spec)),
                "legacy_segment_weights": str(LEGACY_SEGMENT_WEIGHTS),
                "boundary_names_support_mapping": shape_match,
                "mortality_names_support_mapping": mortality_match,
                "mapping_supported": shape_match and mortality_match,
            }
        )

    result = pd.DataFrame(records)
    require(result.mapping_supported.all(), "India mapping evidence did not pass all checks")
    atomic_csv(result, OUTPUT)
    print(result.to_string(index=False))
    print(f"wrote={OUTPUT}")


if __name__ == "__main__":
    main()
