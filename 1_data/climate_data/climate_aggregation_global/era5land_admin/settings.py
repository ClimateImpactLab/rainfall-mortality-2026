"""
settings.py

Country settings for the global ERA5-Land admin files.

This file tells the ERA5-Land scripts where to find each country shapefile,
which columns identify the admin units, and which years to run. The raw
ERA5-Land files come from the monthly global folder defined below.

The global code covers weights, daily/monthly/annual precipitation and
temperature, and annual wind. Panel-ready scripts are separate from the main
aggregation run.

LandScan 2011 is used for population weights. The GPW 2010 land-area point
table is used for area weights.

Be careful when changing ID columns, ID widths, year ranges, or shapefile
paths. Those choices affect every file written for that country.
"""

from dataclasses import dataclass
from dataclasses import field
from pathlib import Path


# -----------------------------
# Shared Paths
# -----------------------------

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = Path("/project/cil/gcp/estimation/rainfall-mortality/climate_data")
CLIMATE_ROOT = Path("/project/cil/gcp/climate/ERA5-LAND-GLOBAL/raw/daily/global")
PRODUCT = "ERA5-LAND-GLOBAL"
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
    climate_region: str
    shapefile: Path
    id_columns: tuple[str, ...]
    name_columns: tuple[str, ...]
    id_widths: dict[str, int]
    grid_year: int
    column_aliases: dict[str, str] = field(default_factory=dict)
    shapefile_encoding: str | None = None


COUNTRIES = {
    "BRA": Country(
        code="BRA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="brazil",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/BRA/Shapefile/BRA_adm2.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME_1", "NAME_2"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 4},
        grid_year=2000,
    ),
    "CHL": Country(
        code="CHL",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/CHL/Shapefile/cl_comunas_geo_mortality_adm2.shp"
        ),
        id_columns=("adm1_id", "adm2_id"),
        name_columns=(),
        id_widths={"adm1_id": 2, "adm2_id": 3},
        grid_year=2000,
    ),
    "CHN": Country(
        code="CHN",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/CHN/Shapefile/china00.shp"
        ),
        id_columns=("PROVGB", "CITYGB", "CNTYGB"),
        name_columns=("EPROV", "ECITY", "ECNTY"),
        id_widths={"PROVGB": 2, "CITYGB": 4, "CNTYGB": 6},
        grid_year=2000,
    ),
    # Colombia mortality rates use the 2018 DANE ADM2 municipality geography.
    # The shapefile stores the five-digit municipality code as MPIO_CDPMP; copy
    # it to adm2_code so climate outputs merge directly to the mortality files.
    "COL": Country(
        code="COL",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/COL/Shapefiles/"
            "SHP_MGN2018_INTGRD_MPIO/MGN_ANM_MPIOS.shp"
        ),
        id_columns=("adm2_code",),
        name_columns=("adm2_name",),
        id_widths={"adm2_code": 5},
        grid_year=2000,
        column_aliases={
            "adm2_code": "MPIO_CDPMP",
            "adm2_name": "MPIO_CNMBR",
        },
    ),
    # Australia mortality is reported at 2011 SA3 geography. The mortality
    # panel stores the SA3 code as admin_id; the cleaned shapefile keeps the
    # same code in adm2_id.
    "AUS": Country(
        code="AUS",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="australia",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/AUS/Shapefiles/1_Clean/"
            "AUS_sa3_2011.gpkg"
        ),
        id_columns=("adm2_id",),
        name_columns=("adm2",),
        id_widths={"adm2_id": 5},
        grid_year=2010,
    ),
    "ECU": Country(
        code="ECU",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=ROOT.parents[1]
        / "mortality_data/1_cleaning/Country_Descriptives/ECU/shapefiles/"
        / "INEC_DPA_2010/SHP/nxcantones.shp",
        id_columns=("adm2_id",),
        name_columns=("adm2_name",),
        id_widths={"adm2_id": 4},
        grid_year=2000,
        column_aliases={
            "adm2_id": "DPA_CANTON",
            "adm2_name": "DPA_DESCAN",
        },
    ),
    "EU": Country(
        code="EU",
        level="nuts2",
        first_year=1950,
        last_year=2025,
        climate_region="europe",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/EU/Shapefile/NUTS2_RG_60M_2013_mortality.shp"
        ),
        id_columns=("NUTS_ID",),
        name_columns=(),
        id_widths={},
        grid_year=2000,
    ),
    "FRA": Country(
        code="FRA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="europe",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/FRA/Shapefile/FRA_adm2.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME_1", "NAME_2"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 2},
        grid_year=2000,
    ),
    # India uses the 1961 district shapefile used by the mortality panel.
    "IND": Country(
        code="IND",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="india",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/IND/Shapefile/1961_districts/1961_districts_final.shp"
        ),
        id_columns=("UNID",),
        name_columns=("STATE_UT", "NAME"),
        id_widths={"UNID": 3},
        grid_year=2000,
    ),
    "JPN": Country(
        code="JPN",
        level="adm1",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/JPN/Shapefile/JPN_adm1.shp"
        ),
        id_columns=("ID_0", "ID_1"),
        name_columns=("NAME_1",),
        id_widths={"ID_0": 3, "ID_1": 2},
        grid_year=2000,
    ),
    "KOR": Country(
        code="KOR",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/KOR/Mortality/dta/shapefile/korea_adm2.shp"
        ),
        id_columns=("adm2_n_",),
        name_columns=("adm_nam",),
        id_widths={"adm2_n_": 5},
        grid_year=2000,
        shapefile_encoding="CP949",
    ),
    "MEX": Country(
        code="MEX",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="mexico",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/MEX/Shapefile/harmonized/"
            "boundaries_4795_IPUMS_MX_HSLAD_1990_2015.shp"
        ),
        id_columns=("GEOID",),
        name_columns=("LABEL",),
        id_widths={"GEOID": 9},
        grid_year=2000,
    ),
    "USA": Country(
        code="USA",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="usa",
        shapefile=Path(
            "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/"
            "Countries/USA/Shapefile/tl_2016_us_county_mortality.shp"
        ),
        id_columns=("ID_0", "ID_1", "ID_2"),
        name_columns=("NAME", "NAMELSAD"),
        id_widths={"ID_0": 3, "ID_1": 2, "ID_2": 3},
        grid_year=2000,
    ),
    "PHL": Country(
        code="PHL",
        level="adm3",
        first_year=1950,
        last_year=2025,
        climate_region="asia_combined",
        shapefile=Path(
            "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/"
            "data/0_data_cleaning/1_raw/Countries/New_Countries/PHL/Shapefiles/"
            "Post2023/PH_Adm3_MuniCities.shp/PH_Adm3_MuniCities.shp.shp"
        ),
        id_columns=("adm1_psgc", "adm2_psgc", "adm3_psgc"),
        name_columns=("adm3_en",),
        id_widths={"adm1_psgc": 9, "adm2_psgc": 9, "adm3_psgc": 9},
        grid_year=2010,
    ),
    "PER": Country(
        code="PER",
        level="adm2",
        first_year=1950,
        last_year=2025,
        climate_region="latam",
        shapefile=ROOT.parents[1]
        / "mortality_data/1_cleaning/Country_Descriptives/PER/ADM2/"
        / "PER_adm2_simplified.geojson",
        id_columns=("shp_adm2_code",),
        name_columns=("shp_adm2_name",),
        id_widths={"shp_adm2_code": 4},
        grid_year=2020,
    ),
}


# -----------------------------
# Derived Paths
# -----------------------------


def country(code: str) -> Country:
    code = code.upper()
    if code not in COUNTRIES:
        raise ValueError(f"Unknown country: {code}")
    return COUNTRIES[code]


def climate_file(spec: Country, variable: str, year: int) -> Path:
    # Use January when a script only needs the grid, not a full year of data.
    return monthly_climate_file(variable, year, 1)


def monthly_climate_file(variable: str, year: int, month: int) -> Path:
    # Global ERA5-Land files are one variable-month per file.
    # Example:
    #   global/tp_total/era5land_global_tp_total_2020_01.nc4
    return (
        CLIMATE_ROOT
        / variable
        / f"era5land_global_{variable}_{year}_{month:02d}.nc4"
    )


def weights_dir(spec: Country) -> Path:
    return OUTPUT_ROOT / "weights/landscan2011" / PRODUCT / spec.code


def weights_file(spec: Country) -> Path:
    slug = spec.code.lower()
    return (
        weights_dir(spec)
        / f"era5land_{slug}_{spec.level}_segment_weights_landscan2011.csv"
    )


def admin_file(spec: Country) -> Path:
    slug = spec.code.lower()
    return weights_dir(spec) / f"era5land_{slug}_{spec.level}_admin_summary.csv"


def result_dir(spec: Country) -> Path:
    return OUTPUT_ROOT / PRODUCT / spec.code
