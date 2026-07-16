# Minimal package loading
library(dplyr)
library(tidyr)
library(fixest)
library(ggplot2)
library(readr)
library(RColorBrewer)
library(MetBrewer)
library(stringr)
library(glue)
library(purrr)
theme_set(theme_classic())

# set paths
USER = Sys.getenv("USER")
setwd(this.path::this.dir())
source("../0_utils/paths.R")

# source functions
source("../0_utils/functions.R")
source("../0_utils/load_mortality_data.R")

# LOAD DATA ---------------------------
df <- read_csv(file.path(DATA_DIR, "mortality_data", "merge", "ghsl_mortality_merged.csv"))

# Regression parameters --------------------------- 
# fixed effects options from from Carleton et al 2022
spec1 <- c("adm2_code^agegroup", "adm0_code^year")
spec2 <- c("adm2_code^agegroup", "adm0_code^year^agegroup") # main specification
spec3 <- c("adm2_code^agegroup", "adm0_code^year^agegroup", "adm1_agegrp_code[year]")
spec4 <- c("adm2_code^agegroup", "adm0_code^year^agegroup", "adm1_code^year^agegroup") # saturated FEs

# Regression ---------------------------
## 0. Replicate main specification from Carleton et al 2022 -----------------------
agespec_response_spec2 <- fit_response(data = df,
                                       tavg_order = 4,
                                       prcp_order = 2,
                                       interact_var = "adm0_code")

## 1. Baseline reg for comparison --------------------
#' default to poly 3 precip, poly 2 temp
#' @param df         data containing an `urban_share` column (0-100).
#' @param prcp_order precip polynomial order (also the response-curve order).
#' @param tavg_order temperature polynomial order.
#' @param x          precip values to evaluate the curve at.
#' @param x_ref      reference precip or temperature value
#' @param fe         fixed-effects spec passed to fit_response.
#' @param log_mort   TRUE -> fepois, FALSE -> feols.
#' @param prefix     prefix for the precip variable in the regression 
#' @param id         label stored in the `id` column of the output.
#' @param suffix     suffix of the climate variable based on the climate produce 
#'                   e.g. GMFD = "", ERA5-Land = "_ERA5LAND" etc.
#' @return response-curve tibble; fitted model attached as attr(rf, "fit").
base_rf <- function(df, 
                    suffix,
                    prcp_order = 3, 
                    tavg_order = 2,
                    x = 0:300,
                    x_ref = 0,
                    fe = spec2,
                    weights = ~weight,
                    log_mort = TRUE,
                    prefix = "prcp_poly_",
                    id = "Precip") {
  
  df$agegroup <- as.factor(df$agegroup)
  agegroups <- levels(df$agegroup)
  
  fit_a <- fit_response(df, 
                        tavg_order = tavg_order, prcp_order = prcp_order,
                        fe = fe, 
                        weights = ~weight,
                        log_mort = log_mort, 
                        suffix = suffix)
  
  key_a <- make_coef_names(prefix = prefix, fit = fit_a, suffix = suffix)
  
  # polynomial order based on climate variable
  poly_order <- if (prefix == "tavg_poly_") tavg_order else prcp_order
  
  rf_a  <- build_response(fit_a, x = x, x_ref = x_ref, poly_order = poly_order,
                          groups = tibble(agegroup = agegroups),
                          key = key_a, id = id)
  rf_a
}

# compare baseline precipitation and temperature response between GMFD and ERA5-Land
suffixes <- c("", "_ERA5LAND")

# using two calls of base_rf in favor of readability
results <- map_dfr(suffixes, function(suffix) {
  bind_rows(
    base_rf(df = df, suffix = suffix),
    base_rf(df = df,
            x = round(seq(-20, 45, by = 0.1), 1),
            x_ref = 27,
            prefix = "tavg_poly_",
            id = "Temperature",
            suffix = suffix)
  ) %>%
    mutate(suffix = if_else(suffix == "", "GMFD", suffix))
})

# write_csv(results, glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.main.spec.csv"))

### 1.1 Check precip order importance in baseline reg --------------------
prcp_orders <- c(2:4)

rf.poly <- map_dfr(prcp_orders, function(prcp_order){
  
  print(paste0("==== running precip poly ", prcp_order, " ======="))
  
  df$agegroup <- as.factor(df$agegroup)
  agegroups <- levels(df$agegroup)
  
  fit <- fit_response(df, tavg_order = 2, prcp_order = prcp_order,
                      fe = spec2,
                      weights = ~weight,
                      log_mort = TRUE)
  
  key <- make_coef_names(prefix = "prcp_poly_", suffix = "_ERA5LAND")
  
  build_response(fit, x = 0:300, poly_order = prcp_order,
                 groups = tibble(agegroup = agegroups),
                 key = key, id = "Precip") %>% 
    mutate(precip_poly = prcp_order)
  })  %>% 
  mutate(precip_poly = as.factor(precip_poly))

rf.poly %>% 
  plot_response(color = "agegroup", facet = "precip_poly",
                xlab = "Precipitation",
                ylab = "Δ deathrate",
                scales = "fixed")

### 1.2 Check under different fixed effects --------------------
# create all combinations of fixed effects, weights, and data suffixes
params <- tidyr::crossing(
  fe      = list(spec1, spec2, spec3, spec4),
  weights = list(~weight), # more weights can be added e.g. list(NULL, ~weight)
  suffix  = c("_ERA5LAND") # more suffixes can be added e.g. c("", "_ERA5LAND")
)

rf.precip.base.fe <- pmap_dfr(params, function(fe, weights, suffix) {
  base_rf(df, fe = fe, weights = weights, suffix = suffix) %>%
    mutate(spec = paste(fe, collapse = "+"),
           weighted = !is.null(weights),
           suffix = if_else(suffix == "", "GMFD", suffix))
})

# write_csv(rf.precip.base.fe, glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.precip.base.fe.csv"))

# temperature response under saturated FEs
rf.base.sat.temp <- base_rf(df = df,
                            x = -20:45,
                            x_ref = 27,
                            fe = spec4,
                            prefix = "tavg_poly_",
                            id = "Temperature",
                            suffix = "_ERA5LAND")

rf.base.sat.temp %>% 
  plot_response(color = "agegroup",
                xlab = "Temperature",
                ylab = "Δ deathrate",
                scales = "fixed")  

## 2. Urban split ----------------------------------------------------
# hist(df$urban_share)
# quantile(df$urban_share, na.rm=T, seq(0, 1, 0.1))

#' default to poly 3 precip, poly 2 temp
#' @param df         data containing an `urban_share` column (0-100).
#' @param n          number of urban groups (e.g. 2, 3, 4, 5, 10).
#' @param prcp_order precip polynomial order (also the response-curve order).
#' @param tavg_order temperature polynomial order.
#' @param x          precip values to evaluate the curve at.
#' @param x_ref      reference precip or temperature value
#' @param fe         fixed-effects spec passed to fit_response.
#' @param log_mort   TRUE -> fepois, FALSE -> feols.
#' @param prefix     prefix for the precip variable in the regression 
#' @param id         label stored in the `id` column of the output.
#' @param suffix     suffix of the climate variable based on the climate produce 
#'                   e.g. GMFD = "", ERA5-Land = "_ERA5LAND" etc.
#' @return response-curve tibble; fitted model attached as attr(rf, "fit").
urban_rf <- function(df, n,
                     prcp_order = 3, tavg_order = 2,
                     x = 0:300,
                     x_ref = 0,
                     fe = spec2,
                     weights = ~weight,
                     log_mort = TRUE,
                     prefix = "prcp_poly_",
                     id = "Precip",
                     suffix = "_ERA5LAND") {
  
  if (!"urban_share" %in% names(df)) {
    stop("`df` must contain `urban_share`")
  }
  
  # Create urban bins
  breaks <- seq(0, 100, length.out = n + 1) # create evenly spaced breaks
  df <- df %>%
    mutate(
      urban_bin = cut(urban_share, breaks = breaks,
                      include.lowest = TRUE, ordered_result = TRUE)
    )
  
  df$agegroup <- as.factor(df$agegroup)
  agegroups <- levels(df$agegroup)
  urban_groups <- levels(df$urban_bin)
  
  fit <- fit_response(df, 
                      tavg_order = tavg_order, prcp_order = prcp_order,
                      interact_var = "urban_bin", 
                      fe = fe, 
                      weights = weights,
                      log_mort = log_mort,
                      suffix = suffix)
  
  key <- make_coef_names(prefix = prefix, 
                         interact_var = "urban_bin", 
                         fit = fit,
                         suffix = suffix)
  
  rf <- build_response(
    fit,
    x = x,
    x_ref = x_ref,
    poly_order = prcp_order,
    groups = tidyr::crossing(agegroup = agegroups, urban_bin = urban_groups),
    key = key,
    id = id
  ) %>%
    mutate(
      bins = paste0("N.bins = ", n),
      urban_bin = factor(urban_bin, levels = urban_groups),
      suffix = suffix
    )
  
  rf
}

### 2.1 change the number of urban share bins, fixed effects and regression weights -----------

# create all combinations of urban share bins, fixed effects and weights
params <- tidyr::crossing(
  NN = c(2:5),
  fe = list(spec1, spec2, spec3, spec4),
  weights = list(NULL, ~weight)
)

# urban response over all combinations 
rf.precip.urban.fe <- pmap_dfr(params, function(NN, fe, weights) {
  urban_rf(df, NN, fe = fe, weights = weights) %>%
    mutate(spec = paste(fe, collapse = "+"),
           weighted = !is.null(weights))
}) %>%
  mutate(bins = as.factor(bins),
         bin_order = as.integer(urban_bin))

# write_csv(rf.precip.urban.fe, glue(DIR_REPO_RAINFALL_MORTALITY, "/output/data/rf/rf.precip.urban.fe.csv"))

## 3. Income * urban group - issue with NA here ---------------------

hist(df$gdppc_adm1_avg)
quantile(df$gdppc_adm1_avg, na.rm=T, seq(0, 1, 0.1))

#' Precip response interacted with (urban-share bin × binary income).
#' Loops the urban binning over `n`, crosses each bin with a rich/poor split,
#' fits a single combined `group` interaction, then splits it back into
#' `urban_bin` and `inc` columns for plotting.
#'
#' @param n             number of urban-share bins (e.g. 2, 3, 4, 5).
#' @param inc_threshold gdppc cutoff for "rich" vs "poor".
urban_inc_rf <- function(df, n,
                         inc_threshold = 20000,
                         prcp_order = 3, tavg_order = 2,
                         x = 0:300,
                         fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"),
                         log_mort = TRUE,
                         agegroups = levels(df$agegroup),
                         id = "Precip") {
  
  stopifnot("urban_share"   %in% names(df),
            "gdppc_adm1_avg" %in% names(df))
  
  inc_levels <- c("poor", "rich")
  
  # urban bins x binary income, combined into one interaction cell.
  # group is NA whenever either piece is NA, so those rows drop out cleanly.
  df <- df %>%
    mutate(
      urban_bin = cut(urban_share, breaks = seq(0, 100, length.out = n + 1),
                      include.lowest = TRUE),
      inc       = if_else(gdppc_adm1_avg > inc_threshold, "rich", "poor"),
      group     = if_else(is.na(urban_bin) | is.na(inc), NA_character_,
                          paste(urban_bin, inc, sep = "__"))
    )
  
  urban_groups <- levels(df$urban_bin)             # cut order, low -> high
  group_levels <- sort(unique(na.omit(df$group)))  # order here doesn't matter
  
  df <- df %>% mutate(group = factor(group, levels = group_levels))
  
  fit <- fit_response(df, tavg_order = tavg_order, prcp_order = prcp_order,
                      interact_var = "group", fe = fe, log_mort = log_mort)
  
  key <- make_coef_names("prcp_poly_", interact_var = "group", fit = fit)
  
  build_response(
    fit, x = x, poly_order = prcp_order,
    groups = tidyr::crossing(agegroup = agegroups, group = group_levels),
    key = key, id = id) %>%
    tidyr::separate(group, into = c("urban_bin", "inc"),
                    sep = "__", remove = FALSE) %>%
    mutate(
      bins      = paste0("N.bins = ", n),
      urban_bin = factor(urban_bin, levels = urban_groups),
      inc       = factor(inc, levels = inc_levels)
    )
}

rf.urban.inc <- map_dfr(2:5, function(NN) urban_inc_rf(df, NN)) %>%
  mutate(bins = as.factor(bins))

# Curves for one binning: panel grid of (age x urban bin), coloured by income
rf.urban.inc <- map_dfr(2:4, function(NN) urban_inc_rf(df, NN)) %>%
  mutate(bins = as.factor(bins))

for(bb in unique(rf.urban.inc$bins)){
  rf.urban.inc %>%
    filter(bins == bb) %>%
    ggplot(aes(x, dy, color = inc, fill = inc)) +
    geom_hline(yintercept = 0, linewidth = 1, alpha = 0.1) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.3, color = NA) +
    geom_line(linewidth = 1) +
    facet_grid(agegroup ~ urban_bin) +
    scale_color_manual(values = met.brewer("Hokusai3", 2)) +
    scale_fill_manual(values  = met.brewer("Hokusai3", 2)) +
    labs(x = "Precipitation", y = "Δ deathrate")
  ggsave(file.path(DIR_FIGURE, paste0("urban_inc_", bb, ".png")))
  
  rf.urban.inc %>%
    dplyr::filter(bins == bb) %>%
    dplyr::filter(x %in% c(100, 200, 300)) %>%
    mutate(x = paste0(x, "mm")) %>%
    ggplot() +
    geom_hline(yintercept = 0, color = "grey") +
    geom_point(aes(urban_bin, dy, color = inc),
               position = position_dodge(width = .5)) +
    geom_errorbar(aes(urban_bin, ymin = lo, ymax = hi, color = inc),
                  position = position_dodge(width = .5)) +
    facet_grid(agegroup ~ bins + x, scales = "free_x") +
    labs(x = "Urban-share bin", y = "Δ deathrate")
  ggsave(file.path(DIR_FIGURE, paste0("urban_inc_errorbars", bb, ".png")))
}


