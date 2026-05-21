#========================================================================================#
#' General purpose functions that will be used throughout the project
#'
#========================================================================================#

#' Load the Carleton et al 2022 mortality panel, cleaned and regression-ready.
#' When load_cleaned = TRUE, reads a cached parquet file (fast).
#' When load_cleaned = FALSE, reads the raw .dta, runs all cleaning steps,
#' and optionally writes the cache for next time.
#'
#' @usage
#' # First time (slow — reads .dta, cleans, writes cache):
#' df <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = FALSE,
#'                           cache_path = "data/mortality_clean.parquet")
#'
#' # Subsequent runs (fast — reads cached parquet):
#' df <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = TRUE,
#'                           cache_path = "data/mortality_clean.parquet")
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
             adm0_code == 40 ~ 40  # USA
           ),
           iso2 = iso,
           iso2 = ifelse(adm0_code2 == 41, "EUR", iso),
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

#' function to generate weights and convert agegroup to factor
#' for regressions using data from Carleton et al 2022.
#' Factor conversion of the precip-interaction variable (if any) is handled
#' inside `fit_response`, since that's where the choice of variable lives.
get_weights <- function(df){
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup)) # convert to factor for feols
}

#' Fit a Carleton-style polynomial regression.
#' tavg_order / prcp_order: 0 to skip that block, otherwise the polynomial order.
#' interact_var: NULL  -> prcp_poly_k × agegroup only
#'               "col" -> col × prcp_poly_k × agegroup interactions, where
#'                       "col" is any categorical column in `data`
#'                       (e.g. "adm0_code", "adm1_id", "climate_zone").
#' Note: `fe` defaults assume a country-style design. When changing
#' `interact_var`, you'll usually want to pass an `fe` that matches the new
#' grouping (e.g. drop `adm0_code^year^agegroup` for adm1-level interactions).
fit_response <- function(data,
                         lhs = "deathrate_w99",
                         tavg_order,
                         prcp_order,
                         interact_var = NULL,
                         log_mort = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup",
                                "adm0_code^year^agegroup"),
                         weights = ~weight,
                         cluster = ~adm1_code,
                         ...) {

  # ensure the interaction variable is a factor so feols treats it as categorical
  if (!is.null(interact_var)) {
    if (!interact_var %in% names(data)) {
      stop("interact_var '", interact_var, "' not found in data")
    }
    if (!is.factor(data[[interact_var]])) {
      data[[interact_var]] <- as.factor(data[[interact_var]])
    }
  }

  # build rhs
  rhs <- character() # initialize an empty character vector to hold all terms

  # create the temperature polynomial only when tavg order is more than zero
  if (tavg_order > 0) {
    rhs <- c(rhs, paste0("i(agegroup, tavg_poly_", seq_len(tavg_order), ")"))
  }

  # create the precipitation polynomial only when precip order is more than zero
  if (prcp_order > 0) {
    # create different precip terms based on whether interact_var is set
    rhs <- c(rhs, if (!is.null(interact_var)) {
      paste0(interact_var, ":prcp_poly_", seq_len(prcp_order), ":agegroup")
    } else {
      paste0("i(agegroup, prcp_poly_", seq_len(prcp_order), ")")
    })
  }
  
  # create the formula for feols
  f <- as.formula(sprintf("%s ~ %s | %s",
                          lhs,
                          paste(rhs, collapse = " + "), # combine rhs, separated by +
                          paste(fe, collapse = " + "))) # combine fixed effects, separated by +
  
  # run the regression
  if (log_mort) {
    fepois(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
  } else {
    feols(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
  }
}

#' Coefficient-name template that matches what `fit_response` produces.
#' Picks the right naming convention based on `interact_var`.
#' interact_var: NULL  -> consistent `agegroup::X:prefixK` pattern
#'               "col" -> token-match against the fitted coefficient names,
#'                       expecting tokens like "<col><level>", "agegroup<lvl>"
#'                       and "<prefix><k>". The `groups` tibble passed to
#'                       `build_response` must contain a column named `col`.
#' prefix: prcp_poly_ or tavg_poly_
make_coef_names <- function(prefix, interact_var = NULL, fit = NULL) {

  if (!is.null(interact_var)) {
    if (is.null(fit)) {
      stop("interact_var requires `fit` to look up coefficient names from the fitted model")
    }
    cn <- names(coef(fit)) # collect feols coefficient names
    cn_tok <- strsplit(cn, ":", fixed = TRUE) # split them by colon

    # a function of group (g) and polynomial (k) order that returns coefficient name
    function(g, k) {
      # build the set of expected tokens in the coefficient name
      want <- c(paste0(interact_var, g[[interact_var]]),
                paste0("agegroup",  g$agegroup),
                paste0(prefix, k))
      # check whether there's a matching token and find the indices where the match is true
      hits <- which(vapply(cn_tok, setequal, logical(1), want))
      # ensure that the coefficient name is returned only in the case of one match
      if (length(hits) == 1) cn[hits] else NA_character_
    }
  } else {
    function(g, k) sprintf("agegroup::%s:%s%d", g$agegroup, prefix, k)
  }
}

#' Polynomial response f(x) − f(x_ref) with delta-method SE. 
#' b: coefficients
#' V: variance-covariance matrix
#' x: temperature or precipitation values
#' coef_names: coefficient names come from calling make_coef_names before this 
#'             function inside build_response function
#' x_ref: reference precipitation (0mm) or temperature (27C)
poly_response <- function(b, V, x, coef_names, x_ref = 0) {
  
  P <- length(coef_names) # number of coefficient names = polynomial order
  xpow <- outer(x, 1:P, `^`) - matrix(x_ref^(1:P), nrow = length(x), ncol = P,
                                      byrow = TRUE) # raise each x value to power 1 to P and subtract reference values from it
  Vsub <- V[coef_names, coef_names, drop = FALSE] #  extract variance-covariance matrix for the relevant coefficients
  dy <- as.numeric(xpow %*% b[coef_names]) # predicted response
  se <- sqrt(rowSums((xpow %*% Vsub) * xpow)) # sqrt(x' V x) for each point 

  # return a tidyverse dataframe
  tibble(x = x, dy = dy, se = se, lo = dy - 1.96*se, hi = dy + 1.96*se)
}

#' Build response curves across grouping combinations, relative to x_ref.
#' fit: name of the fit
#' x: temperature or precipitation values
#' poly_order: order of the temperature or precipitation polynomial
#' groups: grouping variable e.g. agegroup, adm0_code etc
#' key: dictionary of coefficient names from make_coef_names function
#' x_ref: reference precipitation or temperature
#' id: which of temperature or precipitation
build_response <- function(fit, x, poly_order, groups, key,
                           x_ref = 0, id = "") {
  # extract coefficients, variance-covariance matrix, and coefficient names from the fitted model upfront
  b <- coef(fit); V <- vcov(fit); cn <- names(b)
  
  # use make_coef_names and poly_response to output response data
  out <- groups %>%
    mutate(.gid = row_number()) %>% # assign numeric group ID to each row
    group_by(.gid) %>%
    # iterate over each group
    group_modify(~ {
      # apply make_coef_names to all terms of the current group
      nms <- vapply(seq_len(poly_order),
                    function(k) key(.x, k), character(1))
      # return NA values if coefficient name does not exist
      if (!all(nms %in% cn)) {
        return(tibble(x = x, dy = NA_real_, se = NA_real_,
                      lo = NA_real_, hi = NA_real_))
      }
      # compute response curve for each x value
      poly_response(b, V, x, nms, x_ref = x_ref)
    }) %>%
    ungroup() %>%
    # reattach original group columns
    left_join(mutate(groups, .gid = row_number()), by = ".gid") %>%
    select(-.gid) %>%
    mutate(id = id)
  
  # report dropped cells
  dropped <- out %>%
    filter(is.na(dy)) %>%
    distinct(across(all_of(names(groups))))
  if (nrow(dropped) > 0) {
    message("build_response: dropped ", nrow(dropped),
            " cell(s) with no estimated coefficients:")
    message(paste(utils::capture.output(print(dropped)), collapse = "\n"))
  }
  
  # remove missing y_hat values
  out %>% filter(!is.na(dy))
}

#' Plot response
#' 
plot_response <- function(rf_data, color = "agegroup", facet = NULL,
                          xlab = NULL, ylab = "Δ outcome (vs x = ref)",
                          scales='fixed') {
  
  color_palette <- met.brewer("Hokusai3", n = 3)
  
  p <- ggplot(rf_data, aes(x, dy, color = .data[[color]], fill = .data[[color]])) +
    geom_hline(yintercept=0, linewidth = 1, color="black", alpha=0.1)+
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.3, color = NA) +
    geom_line(linewidth = 1) +
    scale_color_manual(values = color_palette) +
    scale_fill_manual(values = color_palette) +
    labs(x = xlab, y = ylab) +
    theme_classic() +
    theme(legend.key.spacing.y = unit(0.3, "cm") ,
          legend.key.width = unit(1.5, "cm"),
          axis.line = element_line(color = "black", linewidth = 1),
          axis.text = element_text(size = 10),
          axis.title = element_text(size = 14),
          plot.title = element_text(size = 16, face = "bold"),
          strip.text = element_text(size = 12)) +
  guides(fill = "none")
  if (!is.null(facet)) p <- p + facet_wrap(facet, scales = scales)
  p
}
