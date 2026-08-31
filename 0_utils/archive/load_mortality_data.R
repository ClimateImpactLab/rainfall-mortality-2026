#========================================================================================#
#' Load the old Carleton mortality panel
#'
#' This is used by the old archived regression scripts. The current rebuilt
#' rainfall-mortality panel is loaded in `2_analysis/regressions/00_prep_analysis_panel.R`.
#'
#' When `load_cleaned = TRUE`, read a cached parquet file if it exists.
#' When `load_cleaned = FALSE`, read the raw Stata file and rebuild the cache.
#'
#' @usage
#' df <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = FALSE,
#'                           cache_path = file.path(DATA_DIR, "cleaned", "mortality_clean.parquet"))
#========================================================================================#

load_mortality_data <- function(data_dir,
                                load_cleaned = TRUE,
                                cache_path = NULL) {
  
  # -----------------------------
  # Cached panel
  # -----------------------------

  if (load_cleaned && !is.null(cache_path) && file.exists(cache_path)) {
    message("Reading cached clean panel from: ", cache_path)
    return(arrow::read_parquet(cache_path))
  }
  
  if (load_cleaned && !is.null(cache_path) && !file.exists(cache_path)) {
    message("Cache not found at: ", cache_path,
            "\nRebuilding from raw .dta file...")
  }
  
  # -----------------------------
  # Raw panel
  # -----------------------------

  message("Reading raw .dta file (this may take a few minutes)...")
  df <- haven::read_dta(
    glue::glue(data_dir, "0_data_cleaning/3_final/global_mortality_panel.dta")
  )
  
  # Drop variable families not used in the old rainfall regressions.
  df <- df %>%
    select(
      -contains("BEST"),
      -contains("Spline"),
      -contains("bins"),
      -contains("rcs"),
      -contains("cdd"),
      -contains("hdd"),
      -contains("UDEL"),
      -contains("13"),
      -contains("tmax")
    )
  
  # -----------------------------
  # Old regression sample
  # -----------------------------
  
  # Old regressions used years through 2010 and age-specific mortality only.
  df <- df %>%
    filter(year <= 2010, agegroup != 0)
  
  # Winsorize death rates separately by country and age group.
  df <- df %>%
    group_by(iso, agegroup) %>%
    mutate(
      deathrate_w99 = pmin(
        deathrate,
        quantile(deathrate, 0.99, na.rm = TRUE, type = 2)
      )
    ) %>%
    ungroup()
  
  # Keep rows with the variables required by the old GMFD regression.
  df <- df %>%
    filter(
      !is.na(deathrate_w99),
      !is.na(tavg_poly_1_GMFD),
      !is.na(prcp_poly_1_GMFD),
      !is.na(loggdppc_adm1_avg),
      !is.na(lr_tavg_GMFD_adm1_avg)
    )
  
  # -----------------------------
  # IDs used by old regressions
  # -----------------------------

  # Japan used ADM1 as the analysis unit in the old panel.
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
  
  # EU countries are grouped together for the old country-year fixed effects.
  df <- df %>%
    mutate(
      adm0_code2 = 41,
      adm0_code2 = case_when(
        adm0_code == 4 ~ 4,   # BRA
        adm0_code == 6 ~ 6,   # CHL
        adm0_code == 7 ~ 7,   # CHN
        adm0_code == 15 ~ 15, # FRA
        adm0_code == 23 ~ 23, # JPN
        adm0_code == 27 ~ 27, # MEX
        adm0_code == 40 ~ 40, # USA
        .default = 41
      ),
      iso2 = iso,
      iso2 = ifelse(adm0_code2 == 41, "EU", iso),
      CHN_ts = 1,
      CHN_ts = ifelse(year >= 2004 & iso == "CHN", 2, CHN_ts)
    )

  # -----------------------------
  # Final variables
  # -----------------------------
  
  # Strip the GMFD suffix used in the raw old panel.
  names(df) <- stringr::str_remove_all(names(df), "_GMFD")
  
  # Add regression weights and the log mortality outcome.
  df <- get_weights(df) %>%
    mutate(log_deathrate_w99 = log(deathrate_w99))
  
  # -----------------------------
  # Write cache
  # -----------------------------

  if (!is.null(cache_path)) {
    dir.create(dirname(cache_path), showWarnings = FALSE, recursive = TRUE)
    arrow::write_parquet(df, cache_path)
    message("Cached clean panel to: ", cache_path)
  }
  
  df
}
