"""
settings.py

Country settings for the CHIRPS admin aggregation.

Lists shapefiles, admin IDs and names, year ranges, one grid-read year, and the
CHIRPS-specific small-cell rules for each country.

CHIRPS provides precipitation only. Population weights use LandScan 2011 and
area weights use the GPW 2010 land-area point table.

Changes to admin IDs, ID widths, year ranges, shapefiles, or CHIRPS cell rules
affect every file produced for that country.
"""

from dataclasses import dataclass, field
from pathlib import Path


# -----------------------------
# Shared paths
# -----------------------------

ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[4]
OUTPUT_ROOT = Path("/project/cil/gcp/estimation/rainfall-mortality/climate_data")
CHIRPS_ROOT = Path(
    "/project/cil/gcp/climate/CHIRPS/Raw_NetCDF_p05deg_by_p05deg/PRCP"
)
LANDSCAN = Path(
    "/project/cil/battuta_shares/gcp/social/sources/Landscan2011/"
    "RasterGISbinary/lspop2011.flt"
)
GPW_LAND_AREA = Path("/project/cil/gcp/temp_data/gpw_2010_land_area_points")


# -----------------------------
# Country settings
# -----------------------------


@dataclass(frozen=True)
class Country:
    code: str
    level: str
    first_year: int
    last_year: int
    shapefile: Path
    id_columns: tuple[str, ...]
    name_columns: tuple[str, ...]
    id_widths: dict[str, int]
    # One year used only to read the CHIRPS grid.
    pilot_year: int
    column_aliases: dict[str, str] = field(default_factory=dict)
    shapefile_encoding: str | None = None
    # Rule for weighted CHIRPS cells that are masked in the raw precipitation file.
    masked_cell_rule: str = "keep_missing"
    # Search radius measured in CHIRPS grid cells.
    masked_cell_max_radius: int = 0
    # Rule for small polygons with no CHIRPS grid-cell center.
    uncovered_cell_rule: str = "keep_uncovered"


COUNTRIES = {
    # BRA has two separate CHIRPS issues: some small polygons contain no CHIRPS
    # grid-cell center, and some assigned precipitation cells are masked.
    "BRA": Country(
        code="BRA",
        level="adm2",
        first_year=1997,
        last_year=2024,
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/BRA/Shapefile/BRA_adm2.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME_1", "NAME_2"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 4},
        pilot_year=2000,
        masked_cell_rule="nearest_valid_cell",
        masked_cell_max_radius=250,
        uncovered_cell_rule="nearest_grid_cell",
    ),

    # COL has a few coastal/island polygons assigned to masked CHIRPS cells.
    "COL": Country(
        code="COL",
        level="adm2",
        first_year=1985,
        last_year=2024,
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/COL/Shapefiles/"
            "SHP_MGN2018_INTGRD_MPIO/MGN_ANM_MPIOS.shp"
        ),
        id_columns=("adm2_code",),
        name_columns=("adm2_name",),
        id_widths={"adm2_code": 5},
        pilot_year=2000,
        column_aliases={
            "adm2_code": "MPIO_CDPMP",
            "adm2_name": "MPIO_CNMBR",
        },
        masked_cell_rule="nearest_valid_cell",
        masked_cell_max_radius=60,
    ),

    # Australia mortality uses SA3 geography.
    # The cleaned shapefile stores the same SA3 code in adm2_id.
    "AUS": Country(
        code="AUS",
        level="adm2",
        first_year=2001,
        last_year=2024,
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/AUS/Shapefiles/1_Clean/"
            "AUS_sa3_2011.gpkg"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2",),
        id_widths={"adm2_id": 5},
        pilot_year=2010,
    ),

    "ECU": Country(
        code="ECU",
        level="adm2",
        first_year=1990,
        last_year=2024,
        shapefile=(
            REPO_ROOT
            / "1_data/mortality_data/1_cleaning/Mortality/ECU/shapefiles/"
            "INEC_DPA_2010/SHP/nxcantones.shp"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2_name",),
        id_widths={"adm2_id": 4},
        pilot_year=2000,
        column_aliases={
            "adm2_id": "DPA_CANTON",
            "adm2_name": "DPA_DESCAN",
        },
    ),

    "IND": Country(
        code="IND",
        level="adm2",
        first_year=1981,
        last_year=2024,
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/IND/Shapefile/1961_districts/1961_districts_final.shp"
        ),
        id_columns=("UNID",),
        name_columns=("STATE_UT", "NAME"),
        id_widths={"UNID": 3},
        pilot_year=2000,
    ),

    "JPN": Country(
        code="JPN",
        level="adm1",
        first_year=1981,
        last_year=2024,
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/JPN/Shapefile/JPN_adm1.shp"
        ),
        id_columns=("ID_0", "ID_1"),
        name_columns=("NAME_1",),
        id_widths={"ID_0": 3, "ID_1": 2},
        pilot_year=2000,
    ),

    "KOR": Country(
        code="KOR",
        level="adm2",
        first_year=1997,
        last_year=2017,
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/KOR/Mortality/dta/shapefile/korea_adm2.shp"
        ),
        id_columns=("adm2_n_",),
        name_columns=("adm_nam",),
        id_widths={"adm2_n_": 5},
        pilot_year=2000,
        # The shapefile DBF uses Korean text encoding.
        shapefile_encoding="CP949",
    ),

    "MEX": Country(
        code="MEX",
        level="adm2",
        first_year=1990,
        last_year=2024,
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/MEX/Shapefile/harmonized/"
            "boundaries_4795_IPUMS_MX_HSLAD_1990_2015.shp"
        ),
        id_columns=("GEOID",),
        name_columns=("LABEL",),
        id_widths={"GEOID": 9},
        pilot_year=2000,
    ),

    # PHL has some small island municipalities assigned to masked CHIRPS cells.
    "PHL": Country(
        code="PHL",
        level="adm3",
        first_year=2006,
        last_year=2024,
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/PHL/Shapefiles/"
            "Post2023/PH_Adm3_MuniCities.shp/PH_Adm3_MuniCities.shp.shp"
        ),
        id_columns=("adm1_psgc", "adm2_psgc", "adm3_psgc"),
        name_columns=("adm3_en",),
        id_widths={"adm1_psgc": 9, "adm2_psgc": 9, "adm3_psgc": 9},
        pilot_year=2010,
        masked_cell_rule="nearest_valid_cell",
        masked_cell_max_radius=20,
    ),

    "PER": Country(
        code="PER",
        level="adm2",
        first_year=2017,
        last_year=2024,
        shapefile=(
            REPO_ROOT
            / "1_data/mortality_data/1_cleaning/Mortality/PER/ADM2/"
            "PER_adm2_simplified.geojson"
        ),
        id_columns=("shp_adm2_code",),
        name_columns=("shp_adm2_name",),
        id_widths={"shp_adm2_code": 4},
        pilot_year=2020,
    ),
}


# -----------------------------
# Derived paths
# -----------------------------


def country(code: str) -> Country:
    # Use one spelling of the country code everywhere downstream.
    code = code.upper()
    if code not in COUNTRIES:
        raise ValueError(f"Unknown CHIRPS country: {code}")
    return COUNTRIES[code]


def climate_file(year: int) -> Path:
    # Raw CHIRPS files are one NetCDF per year.
    return CHIRPS_ROOT / f"chirps-v2.0.{year}.days_p05.nc"


def weights_dir(spec: Country) -> Path:
    # Weight files sit with the other climate weights, split by source.
    # These are LandScan 2011 population weights for CHIRPS cells.
    return OUTPUT_ROOT / "weights/landscan2011/CHIRPS" / spec.code


def weights_file(spec: Country) -> Path:
    # One row per admin unit x CHIRPS grid cell.
    slug = spec.code.lower()
    return weights_dir(spec) / f"chirps_{slug}_{spec.level}_segment_weights_landscan2011.csv"


def admin_file(spec: Country) -> Path:
    # One row per admin unit, with coverage and weight-sum checks.
    slug = spec.code.lower()
    return weights_dir(spec) / f"chirps_{slug}_{spec.level}_admin_summary.csv"


def result_dir(spec: Country) -> Path:
    # Daily, monthly, and annual precipitation files are written below here.
    return OUTPUT_ROOT / "CHIRPS" / spec.code
