#packages = c("tidyr", "ggplot2", "dplyr", "readr", "glue", "scales", "stringr", "fixest", "haven")

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
REPO <- "~/repos/"
source(glue("{REPO}/rainfall-mortality-2026/0_utils/paths.R"))
source(glue("{REPO}/rainfall-mortality-2026/0_utils/functions.R"))

# LOAD DATA ---------------------------
mortality_data <- 
  paste0(DATA_DIR, "/cleaned/global_rainfall-mortality_panel.csv") %>% 
  read_csv() %>% 
  get_weights() %>%
  mutate(log_deathrate_w99 = log(deathrate_w99)) 

# prep mortality for merge with GHSL data
mortality_data <- mortality_data %>%
  mutate(iso2 = if_else(is.na(iso2), "EU", iso2), # add iso value for EU
         year_5s = round(year / 5) * 5, # column for every fifth year like in GHSL data
         year_5s = if_else(year_5s < 1975, 1975, year_5s), # GHSL data starts in 1975 
         adm1_id = if_else(iso2 == "CHL" | iso2 == "MEX", str_pad(adm1_id, width = 2, pad = "0"), adm1_id), # add leading zero to adm1 code in Chile and Mexico
         adm2_id = if_else(iso2 == "JPN", NA, adm2_id)) # remove adm2 code from Japan

# Load admin urbanisation data
urban <- paste0(DATA_DIR, 
                "/heterogeniety_data/ghsl/cleaned/", 
                "ghsl_pop_landuse_popshare.csv") %>% 
  read_csv()

urban_long <- urban %>%
  pivot_longer(cols = matches("_[0-9]{4}$"),
               names_to = c(".value", "year"),
               names_pattern = "(.+)_(\\d{4})") %>%
  mutate(year = as.double(year)) %>%
  rename(population = sum.POP,
         settlement_type = majority.SMOD)

# Join
df <- left_join(mortality_data, urban_long, 
                by = c("iso2", "adm1_id"="ID_1","adm2_id"="ID_2", "year_5s" = "year"))

# check missing data
df %>% 
  filter(is.na(urban_share)) %>%
  select(adm0, adm1, adm1_id, adm2, adm2_id, year, year_5s, agegroup, urban_share)


# Regression ---------------------------

agegroups <-  levels(df$agegroup)

# 1. Baseline reg for comparison--------------------
fit_a <- fit_response(df, tavg_order = 2, prcp_order = 2,
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"), 
                      log_mort = TRUE)
key_a <- make_coef_names("prcp_poly_")
rf_a  <- build_response(fit_a, x = 0:300, poly_order = 2,
                        groups = tibble(agegroup = agegroups),
                        key = key_a, id = "Precip")

p_a <- plot_response(rf_a, color = "agegroup",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (baseline)")
p_a

# 1.1 Check precip order importance in baseline reg
prcp_orders <- c(2, 3, 4)

rf.poly <- 
  map_dfr(
    prcp_orders, 
    function(prcp_order){
      print(paste0("==== running precip poly ", prcp_order, " ======="))
      fit <- fit_response(df, tavg_order = 2, prcp_order = prcp_order,
                          fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"),
                          log_mort = TRUE)
      
      key <- make_coef_names("prcp_poly_")
      
      build_response(fit, x = 0:300, poly_order = prcp_order,
                           groups = tibble(agegroup = agegroups),
                           key = key, id = "Precip") %>% 
        mutate(precip_poly = prcp_order)
    }
  )  %>% 
  mutate(precip_poly = as.factor(precip_poly))

rf.poly %>% 
  plot_response(color = "precip_poly", facet = "agegroup",
                xlab = "Precipitation",
                ylab = "Δ deathrate",
                scales = "fixed")

# 2. Urban split ----------------------------------------------------
# default to poly 3 precip, poly 2 temp

# hist(df$urban_share)
# quantile(df$urban_share, na.rm=T, seq(0, 1, 0.1))

#' @param df         data containing an `urban_share` column (0-100).
#' @param n          number of urban groups (e.g. 2, 3, 4, 5, 10).
#' @param prcp_order precip polynomial order (also the response-curve order).
#' @param tavg_order temperature polynomial order.
#' @param x          precip values to evaluate the curve at.
#' @param fe         fixed-effects spec passed to fit_response.
#' @param log_mort   TRUE -> fepois, FALSE -> feols.
#' @param agegroups  age-group levels to cross with (defaults to df's levels).
#' @param id         label stored in the `id` column of the output.
#' @return response-curve tibble; fitted model attached as attr(rf, "fit").
urban_rf <- function(df, n,
                     prcp_order = 3, tavg_order = 2,
                     x = 0:300,
                     fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"),
                     log_mort = TRUE,
                     agegroups = levels(df$agegroup),
                     id = "Precip") {
  
  if (!"urban_share" %in% names(df)) {
    stop("`df` must contain `urban_share`")
  }
  
  # Create urban bins
  breaks <- seq(0, 100, length.out = n + 1)
  df <- df %>%
    mutate(
      urban_bin = cut(urban_share, breaks = breaks,
        include.lowest = TRUE, ordered_result = TRUE)
    )
  
  urban_groups <- levels(df$urban_bin)
  
  fit <- fit_response(df, tavg_order = tavg_order, prcp_order = prcp_order,
                      interact_var = "urban_bin", fe = fe, log_mort = log_mort)
  
  key <- make_coef_names("prcp_poly_", interact_var = "urban_bin", fit = fit)
  
  rf <- build_response(
    fit,
    x = x,
    poly_order = prcp_order,
    groups = tidyr::crossing(
      agegroup = agegroups,
      urban_bin = urban_groups
    ),
    key = key,
    id = id
  ) %>%
    mutate(
      bins = paste0("N.bins = ", n),
      urban_bin = factor(urban_bin, levels = urban_groups)
    )
  
  rf
}

rf.urban <- map_dfr(c(2:5), function(NN) urban_rf(df, NN)) %>% 
  mutate(bins = as.factor(bins))

rf.urban %>% 
  filter(x %in% c(100, 200, 300)) %>% 
  mutate(x = paste0(x, 'mm')) %>% 
  ggplot() + 
  geom_hline(yintercept=0, color = 'grey') + 
  geom_point(aes(x = x, y = dy, color= urban_bin), 
             position = position_dodge(width = .5))  + 
  geom_errorbar(aes(x = x, ymin = lo, ymax= hi, color= urban_bin), 
                position = position_dodge(width = .5)) + 
  ylab("Proportion") + 
  facet_wrap(~agegroup+bins, nrow=3)

# rf.urban %>% 
#   plot_response(color = NA, facet = c("urban_bin, agegroup"),
#                 xlab = "Precipitation",
#                 ylab = "Δ deathrate",
#                 scales = "fixed")

# 3. Income * urban group - issue with NA here ---------------------

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


