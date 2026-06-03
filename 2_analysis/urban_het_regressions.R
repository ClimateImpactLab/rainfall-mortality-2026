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
theme_set(theme_classic())

# set paths
USER = Sys.getenv("USER")
source(glue("/project/cil/home_dirs/{USER}/repos/rainfall-mortality-2026/0_utils/paths.R"))
source(glue("/project/cil/home_dirs/{USER}/repos/rainfall-mortality-2026/0_utils/functions.R"))

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

# Regression ---------------------------
# check missing data
df %>% 
  filter(is.na(urban_share)) %>%
  select(adm0, adm1, adm1_id, adm2, adm2_id, year, year_5s, agegroup, urban_share)

agegroups <-  levels(df$agegroup)

# 1. Baseline reg for comparison
fit_a <- fit_response(df, tavg_order = 4, prcp_order = 2,
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

# 2. Urban split 
hist(df$urban_share)
quantile(df$urban_share, na.rm=T, seq(0, 1, 0.1))

df <- df %>% 
  mutate(urban_bin_2 = as.factor(if_else(urban_share > 0, "urban", "rural")),
         urban_bin_3 = as.factor(cut(urban_share, breaks = c(0, 33, 66, 100), include.lowest = TRUE)),
         urban_bin_4 = as.factor(cut(urban_share, breaks = seq(0, 100, by = 25), include.lowest = TRUE)),
         urban_bin_5 = as.factor(cut(urban_share, breaks = seq(0, 100, by = 20), include.lowest = TRUE)),
         urban_bin_10 = as.factor(cut(urban_share, breaks = seq(0, 100, by = 10), include.lowest = TRUE)))

# Simplest urban-het first attempt: cut into binary variable: 
urban_groups <- levels(df$urban_bin_2)

fit_urban <- fit_response(df, tavg_order = 4, prcp_order = 2,
                      interact_var = "urban_bin_2",
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"), 
                      log_mort=TRUE)
etable(fit_urban)
key_urban <- make_coef_names("prcp_poly_", interact_var = "urban_bin_2", fit = fit_urban)

rf_urban  <- build_response(
  fit_urban, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(agegroup = agegroups,
                           urban_bin_2 = urban_groups),
  key = key_urban, id = "Precip")

p_urban <- plot_response(rf_urban, color = "agegroup", facet = "urban_bin_2",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (× urban_bin_2)",
                     scales = "fixed")
p_urban

# List of all urban/rural bins and precip poly options
bin_cols <- c("urban_bin_2", "urban_bin_3", "urban_bin_4", "urban_bin_5", "urban_bin_10")
prcp_orders <- c(2, 3, 4)

plots_baseline <- list()
# Make baseline plots with all precip poly options
for (prcp_order in prcp_orders) {
  
  fit <- fit_response(df, tavg_order = 2, prcp_order = prcp_order,
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"),
                      log_mort = TRUE)
  
  key <- make_coef_names("prcp_poly_")
  
  rf <- build_response(fit, x = 0:300, poly_order = prcp_order,
                       groups = tibble(agegroup = agegroups),
                       key = key, id = "Precip")
  
  p <- plot_response(rf, color = "agegroup",
                     xlab = glue("Precipitation (poly_order = {prcp_order})"),
                     ylab = "Δ deathrate (baseline)")
  
  plots_baseline[[glue("baseline_prcp{prcp_order}")]] <- p
}
plots_baseline

# Loop over all urban bin options and precip poly options
# first fix the order of the bins
df[bin_cols] <- lapply(df[bin_cols], function(col) {
  factor(col, levels = sort(levels(col)))
})

plots <- list()
for (bin in bin_cols) {
  urban_groups <- levels(df[[bin]])
  
  for (prcp_order in prcp_orders) {
    
    fit <- fit_response(df, tavg_order = 2, prcp_order = prcp_order,
                        interact_var = bin,
                        fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"),
                        log_mort = TRUE)
    
    key <- make_coef_names("prcp_poly_", interact_var = bin, fit = fit)
    
    rf <- build_response(fit, x = 0:300, poly_order = prcp_order,
                         groups = tidyr::crossing(agegroup = agegroups,
                               !!bin := urban_groups),
                         key = key, id = "Precip")
    
    p <- plot_response(rf, color = "agegroup", facet = bin,
                       xlab = glue("Precipitation (poly_order = {prcp_order})"),
                       ylab = glue("Δ deathrate (× {bin})"),
                       scales = "fixed")
    
    plots[[glue("{bin}_prcp{prcp_order}")]] <- p
  }
}
plots

# 3. Income * urban group - issue with NA here
hist(df$gdppc_adm1_avg)
quantile(df$gdppc_adm1_avg, na.rm=T, seq(0, 1, 0.1))
df <- df %>%
  mutate(inc = as.factor(if_else(gdppc_adm1_avg > 20000, "rich", "poor")))
df$group <- as.factor(paste0(df$urban, "_", df$inc))
table(df$group)

group_levels <- levels(df$group)

fit_inc_urban <- fit_response(df, tavg_order = 4, prcp_order = 2,
                          interact_var = "group",
                          fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"), 
                          log_mort=TRUE)
etable(fit_inc_urban)
key_inc_urban <- make_coef_names("prcp_poly_", interact_var = "group", fit = fit_inc_urban)

rf_fit_inc_urban  <- build_response(
  fit_inc_urban, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(agegroup = agegroups,
                           group = group_levels),
  key = key_inc_urban, id = "Precip")

# Remove NA cells - need to come back to this.
rf_fit_inc_urban <- rf_fit_inc_urban %>% filter(!stringr::str_detect(group, "NA"))
p_group <- plot_response(rf_fit_inc_urban, color = "agegroup", facet = "group",
                         xlab = "Precipitation",
                         ylab = "Δ deathrate (× urban)",
                         scales = "fixed")
p_group

df %>% 
  ggplot() + geom_point(aes(x = urban_share, y = gdppc_adm1_avg, color = group))

rf_fit_inc_urban %>% 
  filter(x %in% c(100, 200, 300)) %>% 
  mutate(x = paste0(x, 'mm')) %>% 
  ggplot() + 
  geom_hline(yintercept=0, color = 'grey') + 
  geom_point(aes(x = group, y = dy, color= agegroup), 
             position = position_dodge(width = .5))  + 
  geom_errorbar(aes(x = group, ymin = lo, ymax= hi, color= agegroup), 
                position = position_dodge(width = .5)) + 
  ylab("Proportion") + 
  facet_wrap(~x)
  




