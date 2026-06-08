#' Load the Carleton et al 2022 mortality panel, cleaned and regression-ready.
#' When load_cleaned = TRUE, reads a cached parquet file (fast).
#' When load_cleaned = FALSE, reads the raw .dta, runs all cleaning steps,
#' and optionally writes the cache for next time.
#'
#' @usage
#' # First time (slow — reads .dta, cleans, writes cache):
#' df <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = FALSE,
#'                           cache_path = file.path(DATA_DIR, "cleaned", "mortality_clean.parquet"))
#'
#' # Subsequent runs (fast — reads cached parquet):
#' df <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = TRUE,
#'                           cache_path = file.path(DATA_DIR, "cleaned", "mortality_clean.parquet"))
#'
#' @param data_dir      Carleton et al 2022 data root, e.g. CARLETON_2022_DATA_DIR
#'                      from paths.R.
#' @param load_cleaned  If TRUE, read from cached parquet. If FALSE, rebuild
#'                      from the raw .dta file.
#' @param cache_path    Path to the cached parquet file. Set to NULL to skip
#'                      reading/writing the cache entirely.
#' @return A regression-ready tibble.
load_mortality_data <- function(data_dir,
                                load_cleaned = TRUE,
                                cache_path = NULL) {
  
  # if cached file exists and load_cleaned is TRUE, read and return
  
  if (load_cleaned && !is.null(cache_path) && file.exists(cache_path)) {
    message("Reading cached clean panel from: ", cache_path)
    return(arrow::read_parquet(cache_path))
  }
  
  if (load_cleaned && !is.null(cache_path) && !file.exists(cache_path)) {
    message("Cache not found at: ", cache_path,
            "\nRebuilding from raw .dta file...")
  }
  
  # --- read raw dta ---------------------------------------------------------
  message("Reading raw .dta file (this may take a few minutes)...")
  df <- haven::read_dta(
    glue::glue(data_dir,
               "0_data_cleaning/3_final/global_mortality_panel.dta")
  )
  
  # drop unused column families
  df <- df %>%
    select(-contains("BEST"),
           -contains("Spline"),
           -contains("bins"),
           -contains("rcs"),
           -contains("cdd"),
           -contains("hdd"),
           -contains("UDEL"),
           -contains("13"),
           -contains("tmax"))
  
  # --- prep_data steps (formerly sourced from prep_data.R) -------------------
  
  # filter to estimation sample
  df <- df %>%
    filter(year <= 2010, agegroup != 0)
  
  # winsorize deathrate within country-agegroup
  df <- df %>%
    group_by(iso, agegroup) %>%
    mutate(deathrate_w99 = pmin(deathrate,
                                quantile(deathrate, 0.99,
                                         na.rm = TRUE, type = 2))) %>%
    ungroup()
  
  # restrict to complete cases
  df <- df %>%
    filter(!is.na(deathrate_w99),
           !is.na(tavg_poly_1_GMFD),
           !is.na(prcp_poly_1_GMFD),
           !is.na(loggdppc_adm1_avg),
           !is.na(lr_tavg_GMFD_adm1_avg))
  
  # clean up IDs
  df <- df %>%
    mutate(adm2_id = if_else(iso == "JPN", adm1_id, adm2_id)) %>%
    group_by(iso) %>%
    mutate(adm0_code = cur_group_id()) %>%
    group_by(iso, adm1_id) %>%
    mutate(adm1_code = cur_group_id()) %>%
    group_by(iso, adm1_id, adm2_id) %>%
    mutate(adm2_code = cur_group_id()) %>%
    group_by(iso, agegroup) %>%
    mutate(adm0_agegrp_code = cur_group_id()) %>%
    group_by(iso, adm1_id, agegroup) %>%
    mutate(adm1_agegrp_code = cur_group_id()) %>%
    ungroup()
  
  # assign EU countries same adm0_code
  df <- df %>%
    mutate(adm0_code2 = 41,
           adm0_code2 = case_when(
             adm0_code == 4 ~ 4,   # BRA
             adm0_code == 6 ~ 6,   # CHL
             adm0_code == 7 ~ 7,   # CHN
             adm0_code == 15 ~ 15, # FRA
             adm0_code == 23 ~ 23, # JPN
             adm0_code == 27 ~ 27, # MEX
             adm0_code == 40 ~ 40,  # USA
             .default = 41),
           iso2 = iso,
           iso2 = ifelse(adm0_code2 == 41, "EU", iso),
           CHN_ts = 1,
           CHN_ts = ifelse(year >= 2004 & iso == "CHN", 2, CHN_ts))
  
  # --- steps formerly in run_regressions.R lines 51-53 ----------------------
  
  # strip _GMFD suffix from column names
  names(df) <- stringr::str_remove_all(names(df), "_GMFD")
  
  # generate weights and log deathrate
  df <- get_weights(df) %>%
    mutate(log_deathrate_w99 = log(deathrate_w99))
  
  # --- cache the result ------------------------------------------------------
  if (!is.null(cache_path)) {
    dir.create(dirname(cache_path), showWarnings = FALSE, recursive = TRUE)
    arrow::write_parquet(df, cache_path)
    message("Cached clean panel to: ", cache_path)
  }
  
  df
}