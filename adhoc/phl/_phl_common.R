#========================================================================================#
#' Shared setup for the Philippines study
#'
#' Sourced by every script in adhoc/phl/ (including adhoc/phl/prototype/) so the
#' input panel, the sample definition and the variable scaling stay identical
#' across them. Before this existed the prep block was copy-pasted three times
#' and had already drifted in two places.
#'
#' Defines: PHL_PANEL, PHL_SHP, PHL_SHP_LAYER, AGE_LABS, fmt(),
#'          PRCP_SCALE/TAVG_SCALE,
#'          read_phl_panel(), prep_phl_panel().
#'
#' Assumes adhoc/_common.R has already been sourced (REPO_ROOT, out_dirs()).
#========================================================================================#

source(file.path(REPO_ROOT, "0_utils", "functions.R"))  # get_weights(), fit_response(), ...

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
# --- the mortality panel ----------------------------------------------------
# This study runs on the Philippines rows of the multi-country panel built by
# 1_data/panel_build/ (see its README for how each variable gets there). On the
# cluster that is the canonical file below and no manual step is needed:
# read_phl_panel() does the iso == "PHL" subsetting itself.
#
# Working off-server, a PHL-only extract of the same file is the practical
# alternative, since the full panel is large. It is a plain row subset -- there
# is no separate PHL build -- so the two routes give identical results:
#
#   Rscript -e 'library(dplyr); readr::read_csv("<panel>/new_mortality_panel_urban.csv") |>
#                 filter(iso == "PHL") |> readr::write_csv("local_data/phl/phl_new_mortality_panel_urban.csv")'
#
# Local copies live under local_data/, which is gitignored (adhoc/README.md).
# Point PHL_PANEL_CSV at either shape to override the search.
#
# Upstream of the panel build, PHL mortality comes from
#   .../release_2020/data/0_data_cleaning/3_final/PHL/
#     PHL_mortality_population_panel_adm3_year_agegroup_no_barmm.csv
# which is adm3 x year x agegroup and EXCLUDES BARMM
# (1_data/panel_build/country_files.csv).
PHL_PANEL <- Sys.getenv("PHL_PANEL_CSV", unset = NA_character_)
if (is.na(PHL_PANEL)) {
  .cand <- c(
    # canonical multi-country panel on the cluster, subset to PHL on read
    "/project/cil/gcp/estimation/rainfall-mortality/mortality_data/panel_build/combined_panel/new_mortality_panel_urban.csv",
    # local copies, for working off-server: either shape is accepted
    file.path(REPO_ROOT, "local_data", "phl", "phl_new_mortality_panel_urban.csv"),
    file.path(REPO_ROOT, "local_data", "phl", "new_mortality_panel_urban.csv")
  )
  PHL_PANEL <- .cand[file.exists(.cand)][1]
}

#' Stop with a useful message rather than letting read_csv(NA) throw.
require_phl_panel <- function() {
  if (is.na(PHL_PANEL) || !file.exists(PHL_PANEL)) {
    stop("PHL panel not found; set PHL_PANEL_CSV to its location")
  }
  invisible(PHL_PANEL)
}

# --- the adm3 shapefile -----------------------------------------------------
# PSA PSGC post-2023 municipality/city boundaries. Only 02 and 04 need it.
# The cluster path is the one the panel build itself uses for PHL, recorded in
# 1_data/panel_build/country_files.csv. Note the directory is named
# "PH_Adm3_MuniCities.shp" and the shapefile inside it is
# "PH_Adm3_MuniCities.shp.shp", which is why the layer name below repeats.
# Original source: https://github.com/altcoder/philippines-psgc-shapefiles
# (see 1_data/mortality_data/1_cleaning/Death_Rates/PHL/README.md).
PHL_SHP <- Sys.getenv("PHL_SHP_DIR", unset = NA_character_)
if (is.na(PHL_SHP)) {
  .scand <- c(
    paste0("/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/",
           "0_data_cleaning/1_raw/Countries/New_Countries/PHL/Shapefiles/Post2023/",
           "PH_Adm3_MuniCities.shp"),
    file.path(REPO_ROOT, "local_data", "phl", "shp")
  )
  .hit <- .scand[dir.exists(.scand)]
  PHL_SHP <- if (length(.hit)) .hit[1] else NA_character_
}
PHL_SHP_LAYER <- "PH_Adm3_MuniCities.shp"

require_phl_shp <- function() {
  if (is.na(PHL_SHP) || !dir.exists(PHL_SHP)) {
    stop("PHL adm3 shapefile not found; set PHL_SHP_DIR to the directory ",
         "holding PH_Adm3_MuniCities.shp")
  }
  invisible(PHL_SHP)
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
AGE_LABS <- c("1" = "0-4", "2" = "5-64", "3" = "65+")

#' Format a number for a slide or table.
#' One decimal by default: the PHL outcome is deaths per 100,000, where a second
#' decimal is noise. Pass `d` for counts (d = 0) or shares.
fmt <- function(x, d = 1) formatC(x, format = "f", digits = d, big.mark = ",")

# --- why the climate polynomials are rescaled -------------------------------
# fixest "fixes" a non-PSD clustered VCOV by clipping its eigenvalues at an
# ABSOLUTE 1e-12. In raw units the higher-order polynomial coefficients have
# true variances far below that floor (the cubic precip term is ~1.6e-18), so
# the clip, not the data, ends up determining the standard errors: every
# delta-method SE collapses onto sqrt(1e-12) * x^k. `vcov_fix = FALSE` does not
# disable this in fixest 0.13.2, whether passed to vcov() or to
# vcov_cluster() at fit time.
#
# The robust fix is to reparameterise. Measuring a daily value in units of
# `SCALE` divides the order-k regressor by SCALE^k and multiplies the
# coefficient by SCALE^k, leaving the response function exactly unchanged while
# lifting the coefficient variances well clear of the floor. Section 10 of
# 01_phl_response_functions.R asserts the SEs are scale-invariant at these
# values, which is what "the floor no longer binds" looks like.
PRCP_SCALE <- 100   # 1 regression unit = 100 mm/day
TAVG_SCALE <- 100   # 1 regression unit = 100 degrees C

# ---------------------------------------------------------------------------
# Panel
# ---------------------------------------------------------------------------
#' Read the panel and keep the Philippines rows.
#'
#' The subsetting happens here rather than upstream so the canonical
#' multi-country panel and a PHL-only extract are interchangeable inputs.
read_phl_panel <- function(path = PHL_PANEL) {
  require_phl_panel()
  d <- readr::read_csv(path, show_col_types = FALSE)
  if ("iso" %in% names(d)) {
    n_all <- nrow(d)
    d <- dplyr::filter(d, iso == "PHL")
    if (nrow(d) < n_all) {
      message("panel: kept ", format(nrow(d), big.mark = ","), " PHL rows of ",
              format(n_all, big.mark = ","))
    }
  }
  stopifnot(nrow(d) > 0)
  d
}

#' Prepare the PHL analysis panel.
#'
#' Mirrors the prep in 0_utils/load_mortality_data.R, adapted to a single
#' country (no adm0 dimension, no CHN time-split).
#'
#' poly_k       highest polynomial order to rescale
#' suffixes     climate-product suffixes whose polynomial columns get rescaled
#' alias_tavg   extra suffixes that should receive a copy of the ERA5-Land
#'              temperature polynomial. CHIRPS carries precipitation only, so
#'              aliasing its temperature lets fit_response()'s single-suffix API
#'              run a CHIRPS-precip / ERA5-Land-temperature specification
#'              without modification.
prep_phl_panel <- function(raw, poly_k = 5, suffixes = "_ERA5LAND",
                           alias_tavg = character()) {

  df <- raw %>%
    # agegroup 0 is the all-ages total (its population is the sum of 1/2/3)
    dplyr::filter(agegroup != 0) %>%
    # winsorise deathrate at the 99th pct within agegroup
    dplyr::group_by(agegroup) %>%
    dplyr::mutate(deathrate_w99 = pmin(
      deathrate, quantile(deathrate, 0.99, na.rm = TRUE, type = 2))) %>%
    dplyr::ungroup() %>%
    # complete cases on everything the baseline spec needs
    dplyr::filter(!is.na(deathrate_w99),
                  !is.na(prcp_poly_1_ERA5LAND),
                  !is.na(tavg_poly_1_ERA5LAND),
                  !is.na(population), population > 0) %>%
    # integer admin codes
    dplyr::group_by(adm1_id) %>%
    dplyr::mutate(adm1_code = dplyr::cur_group_id()) %>%
    dplyr::group_by(adm1_id, adm2_id) %>%
    dplyr::mutate(adm2_code = dplyr::cur_group_id()) %>%
    dplyr::group_by(adm1_id, adm2_id, adm3_id) %>%
    dplyr::mutate(adm3_code = dplyr::cur_group_id()) %>%
    dplyr::group_by(adm1_id, adm2_id, agegroup) %>%
    dplyr::mutate(adm2_agegrp_code = dplyr::cur_group_id()) %>%
    dplyr::ungroup() %>%
    # pandemic era, used by the covid fixed effect and the pandemic control
    dplyr::mutate(covid_period = factor(
      dplyr::case_when(year <= 2019 ~ "pre",
                       year <= 2022 ~ "pandemic",
                       TRUE         ~ "post"),
      levels = c("pre", "pandemic", "post")))

  for (sfx in alias_tavg) {
    for (k in seq_len(poly_k)) {
      df[[paste0("tavg_poly_", k, sfx)]] <- df[[paste0("tavg_poly_", k, "_ERA5LAND")]]
    }
  }

  for (sfx in suffixes) {
    for (k in seq_len(poly_k)) {
      pk <- paste0("prcp_poly_", k, sfx)
      tk <- paste0("tavg_poly_", k, sfx)
      if (pk %in% names(df)) df[[pk]] <- df[[pk]] / (PRCP_SCALE^k)
      if (tk %in% names(df)) df[[tk]] <- df[[tk]] / (TAVG_SCALE^k)
    }
  }

  # population weights + agegroup as a factor, from the shared helper
  get_weights(df) %>%
    dplyr::mutate(age_lab = factor(AGE_LABS[as.character(agegroup)],
                                   levels = unname(AGE_LABS)))
}
