# ============================================================================
# 01_build_heterogeneity_panel.R
#
# Global annual panel for the drought heterogeneity regs, from the mortality
# panel built in 1_data/panel_build. Keeps only what the regs use, with
# short names, so 02 only has to run regs.
#
# What it adds or changes:
#   - urban share fixed in time: the panel has GHSL every 5 years, this keeps
#      the value closest to 2000 for every year
#   - fixed in time income: Kummu GDP per capita (log), one var per averaging window,
#      for ex log_gdppc_2000_2010 - 02 picks one (2000-2010 by default)
#   - country_group: the country, with Europe as one group 
#   - fe_adm1: the ADM1 used in the ADM1 x year x age FE 
#
# 3 special cases:
#   1. ADM1 with one admin unit: ADM1 x year x age would have nothing to
#       compare within, so it uses the country instead (for ex Cyprus,
#       Luxembourg)
#   2. Japan: data only available at ADM1/prefectures, so every ADM1 has one
#       admin unit. Instead of the country, Japan uses its standard regions
#       (7 macro-regions), so prefectures are compared within region-year
#   3. Europe: only for the within-country cuts (--cut=within)
#       Most European countries have only a few regions (Luxembourg
#       1, Cyprus 1, Malta 2), too few to cut into terciles, so every European
#       country goes in one "EU" group
#
# Output:
#   /project/cil/gcp/estimation/rainfall-mortality/climate_data/ERA5-LAND/
#     drought/global_annual/global_het_panel.rds
# ============================================================================


# -----------------------------
# Packages
# -----------------------------

library(dplyr)


# -----------------------------
# Paths
# -----------------------------

# defining panel_file (from 1_data/panel_build) and het_panel_file (this script's output)
source("paths.R")


# -----------------------------
# Europe and Japan
# -----------------------------

# European countries, one "EU" group for the within-country cuts
eu_isos <- c("AUT", "BEL", "BGR", "CHE", "CYP", "CZE", "DEU", "DNK", "ESP", "EST", "FIN", "GBR",
             "GRC", "HRV", "HUN", "IRL", "ISL", "ITA", "LIE", "LTU", "LUX", "LVA", "MKD", "MLT",
             "MNE", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "SWE", "TUR")

# Japan's 7 regions and their prefectures. Hokkaido is one prefecture, so
# it goes with Tohoku (alone it would be one admin unit again)
jpn_regions <- list(
  hokkaido_tohoku = c("hokkaido", "aomori", "iwate", "miyagi", "akita", "yamagata", "fukushima"),
  kanto = c("ibaraki", "tochigi", "gunma", "saitama", "chiba", "tokyo", "kanagawa"),
  chubu = c("niigata", "toyama", "ishikawa", "fukui", "yamanashi", "nagano", "gifu", "shizuoka", "aichi"),
  kinki = c("mie", "shiga", "kyoto", "osaka", "hyogo", "nara", "wakayama"),
  chugoku = c("tottori", "shimane", "okayama", "hiroshima", "yamaguchi"),
  shikoku = c("tokushima", "kagawa", "ehime", "kochi"),
  kyushu_okinawa = c("fukuoka", "saga", "nagasaki", "kumamoto", "oita", "miyazaki", "kagoshima", "okinawa")
)

# Prefecture -> region, for ex "chiba" -> "kanto"
jpn_lookup <- setNames(rep(names(jpn_regions), lengths(jpn_regions)), unlist(jpn_regions))


# -----------------------------
# Read the panel
# -----------------------------

# By age group only (0-4, 5-64, 65+):
# all-ages rows (India) and places with no pop are left out.
# Rwanda is left out until its data is ready
panel <- readr::read_csv(panel_file, show_col_types = FALSE,
                         col_types = readr::cols(iso = readr::col_character(),
                                                admin_id = readr::col_character(),
                                                adm1_id = readr::col_character())) %>%
  as_tibble() %>%
  filter(agegroup != 0, population > 0, iso != "RWA")


# -----------------------------
# Urban share
# -----------------------------

# The panel's urban share changes every 5 years (GHSL). Keep each admin unit's
# value closest to 2000 (the earlier one on a tie) and put it on every year
urban <- panel %>%
  filter(!is.na(urban_share)) %>%
  distinct(iso, admin_id, year_5s, urban_share) %>%
  arrange(abs(year_5s - 2000), year_5s) %>%
  distinct(iso, admin_id, .keep_all = TRUE) %>%
  select(iso, admin_id, urban_share)

panel <- panel %>%
  select(-urban_share) %>%
  left_join(urban, by = c("iso", "admin_id"))


# -----------------------------
# IDs and fixed effect groups
# -----------------------------

panel <- panel %>%
  mutate(
    agegroup = factor(agegroup),
    year = as.integer(year),
    admin_code = paste(iso, admin_id, sep = "_"),
    adm1_code = paste(iso, adm1_id, sep = "_"),
    country_group = if_else(iso %in% eu_isos, "EU", iso)
  )

# Japan's region of each prefecture (names without accents or spaces)
panel <- panel %>%
  mutate(jpn_region = jpn_lookup[gsub("[^a-z]", "", tolower(iconv(adm1_name, to = "ASCII//TRANSLIT")))])

# A prefecture name that doesn't match would get no region
stopifnot(!anyNA(panel$jpn_region[panel$iso == "JPN"]))

# ADM1 for the FE: Japan's region, the country where the ADM1 has only one
# admin unit, the ADM1 otherwise
panel <- panel %>%
  group_by(adm1_code) %>%
  mutate(units_in_adm1 = n_distinct(admin_code)) %>%
  ungroup() %>%
  mutate(fe_adm1 = case_when(
    iso == "JPN" ~ paste0("JPN_", jpn_region),
    units_in_adm1 > 1 ~ adm1_code,
    TRUE ~ iso
  ))


# -----------------------------
# Short names and save
# -----------------------------

# The saved panel identifies the climate source. Regressions use short names.
# Strip only ERA5-Land here; any CHIRPS columns keep their source names.
panel <- panel %>%
  rename(tavg_1 = tavg_poly_1_ERA5LAND, tavg_2 = tavg_poly_2_ERA5LAND) %>%
  rename_with(~ sub("_ERA5LAND", "", .x), starts_with("prcp_poly_")) %>%
  rename_with(~ sub("_ERA5LAND", "", .x),
              matches("^(spi12_dry|spi12_dry_roll30|dry_wsum|dry_sum|mckee|dry_x_normal_rolling|dry_x_normal_fixed)_ERA5LAND(_lag1|_lead1)?$")) %>%
  rename_with(~ sub("kummu_loggdppc_avg_", "log_gdppc_", .x), starts_with("kummu_loggdppc_avg_"))

# The 4 drought terms, each at t, t-1 (_lag1) and t+1 (_lead1):
#   - spi12_dry: dry side of the SPI of the January-December total (main)
#   - dry_wsum: monthly SPI dry side summed over the year, each month
#      weighted by its usual share of annual rainfall
#   - dry_sum: same, unweighted
#   - mckee: McKee drought magnitude (months in drought events)
# plus spi12_dry_roll30 (ERA5-Land only): spi12_dry against the 30 years
# before instead of 1981-2010, for --baseline=rolling30 in 02
drought_vars <- c("spi12_dry", "dry_wsum", "dry_sum", "mckee")

# For the drought x normal temp regs (04): monthly SPI dry side x the month's
# normal temp summed over the year (rolling 30 years or 1981-2010), at t, t-1
# and t+1, and the year's normal temps
normal_vars <- c("dry_x_normal_rolling", "dry_x_normal_fixed", "normal_rolling", "normal_fixed")

# Keep only what the regs use: IDs and FE groups, deaths and pop, temp,
# precip poly, drought terms and the het vars. ERA5-Land under the short
# names, CHIRPS (precip poly, drought terms, baseline rainfall) with _CHIRPS,
# for --product=chirps in 02
panel <- panel %>%
  select(
    iso, admin_id, admin_code, adm1_code, fe_adm1, country_group, year, agegroup, deaths, population,
    tavg_1, tavg_2, matches("^prcp_poly_[1-3](_CHIRPS)?(_lag1|_lead1)?$"),
    starts_with(drought_vars), starts_with(normal_vars),
    baseline_prcp_mm, baseline_prcp_cv, baseline_prcp_mm_CHIRPS, baseline_prcp_cv_CHIRPS,
    starts_with("log_gdppc_"), cropland_share, irrigated_share,
    rainfed_share_land, irrigated_share_spam, urban_share
  )

saveRDS(panel, het_panel_file)
message("wrote: ", het_panel_file, " (", nrow(panel), " rows, ", n_distinct(panel$admin_code), " admin units)")
