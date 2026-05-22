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
theme_set(theme_classic())

# set paths
USER <- Sys.getenv("USER")
root <- "/home/tbearpark" # "/project/cil/home_dirs/{USER}/"
setwd(paste0(root, "/repos/rainfall-mortality-2026/"))

source("0_utils/paths.R")
source("0_utils/functions.R")

# LOAD DATA ---------------------------

# load main dataset
mortality_data <- 
  paste0(DATA_DIR, "/cleaned/global_rainfall-mortality_panel.csv") %>% 
  read_csv() %>% 
  get_weights() %>%
  mutate(log_deathrate_w99 = log(deathrate_w99)) 

mortality_data <- mortality_data %>%
  mutate(iso2 = if_else(is.na(iso2), "EU", iso2), # add iso value for EU
         year_5s = round(year / 5) * 5, # column for every fifth year like in GHSL data
         year_5s = if_else(year_5s < 1975, 1975, year_5s)) # GHSL data starts in 1975 

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

# EDA PLOTS ---------------------------
make_eda_plots <- FALSE
if(make_eda_plots){
  urban_long %>%
    filter(settlement_type != 10) %>%
    ggplot() + 
    facet_wrap(~year, nrow = 3) + 
    geom_histogram(aes(x = settlement_type))
  
  urban_long %>%
    filter(settlement_type != 10) %>%
    ggplot() + 
    facet_wrap(~iso2, nrow = 1, scales = "free_y") + 
    geom_bar(aes(x = factor(settlement_type)), width = 0.6) +
    labs(x = "most common land use type in adm unit", 
         y = "number of observations") +
    theme_classic()
  # ggsave(glue(DIR_FIGURE, "/ghsl/iso_hist.png"), width = 14, height = 3)
    
  urban_long %>%
    filter(settlement_type != 10) %>%
    ggplot() + 
    facet_grid(rows = vars(iso2), cols = vars(year), scales = "free_y") + 
    geom_bar(aes(x = factor(settlement_type)), width = 0.6) +
    labs(x = "most common land use type in adm unit", 
         y = "number of observations") +
    theme_minimal() +
    theme(
      strip.text = element_text(face = "bold", size = 14),
      axis.line.x = element_line(color = "black"),
      axis.title = element_text(size = 14),
      axis.text = element_text(size = 10)
    )
  # ggsave(glue(DIR_FIGURE, "/ghsl/iso_year_hist.png"), width = 18, height = 9)
  
  urban_long %>%
    mutate(urban_decile = cut(urban_share, 
                                    breaks = seq(0, 100, by = 10), 
                                    include.lowest = TRUE)) %>%
    ggplot() + 
    facet_grid(rows = vars(iso2), cols = vars(year), scales = "free_y") + 
    geom_histogram(aes(x = urban_share, fill = urban_decile), bins = 25) +
    scale_fill_manual(values = met.brewer("Hokusai3", 10)) +
    labs(fill = "percent range",
         x = "percent of population in urban areas", 
         y = "number of observations") +
    theme_minimal() +
    theme(
      strip.text = element_text(face = "bold", size = 14),
      axis.line.x = element_line(color = "black"),
      axis.title = element_text(size = 14),
      axis.text = element_text(size = 10)
    )
  # ggsave(glue(DIR_FIGURE, "/ghsl/pct_urban_pop.png"), width = 18, height = 9)
  
  # check how to display proportion of admin units on y-axis
  urban_long %>%
    mutate(urban_decile = cut(urban_share, 
                              breaks = seq(0, 100, by = 10), 
                              include.lowest = TRUE)) %>%
    ggplot() + 
    facet_grid(rows = vars(iso2), cols = vars(year), scales = "free_y") + 
    geom_histogram(aes(x = urban_share, fill = urban_decile, y = after_stat(count/sum(count))), bins = 25) +
    # scale_y_continuous(labels = percent_format()) +
    scale_fill_manual(values = met.brewer("Hokusai3", 10)) +
    labs(fill = "most common land use type in adm unit",
         x = "percent of population in urban areas", 
         y = "number of observations") +
    theme_minimal() +
    theme(
      strip.text = element_text(face = "bold", size = 14),
      axis.line.x = element_line(color = "black"),
      axis.title = element_text(size = 14),
      axis.text = element_text(size = 10)
    )
}
# should add some maps and time series...

# Regression ---------------------------

# @Nishka: - there are some missing values, not sure why that is?
df %>% filter(is.na(urban_share))

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

# 2. Simplest urban-het first attempt: cut into binary variable: 
hist(df$urban_share)
quantile(df$urban_share, na.rm=T, seq(0, 1, 0.1))

df <- df %>% 
  mutate(urban = as.factor(if_else(urban_share > 0, "urban", "rural")))

# Urban split
urban_groups <-  levels(df$urban)
fit_urban <- fit_response(df, tavg_order = 4, prcp_order = 2,
                      interact_var = "urban",
                      fe = c("adm2_code^agegroup", "adm0_code^year^agegroup"), 
                      log_mort=TRUE)
etable(fit_urban)
key_urban <- make_coef_names("prcp_poly_", interact_var = "urban", fit = fit_urban)

rf_urban  <- build_response(
  fit_urban, x = 0:300, poly_order = 2,
  groups = tidyr::crossing(agegroup = agegroups,
                           urban = urban_groups),
  key = key_urban, id = "Precip")

p_urban <- plot_response(rf_urban, color = "agegroup", facet = "urban",
                     xlab = "Precipitation",
                     ylab = "Δ deathrate (× urban)",
                     scales = "fixed")
p_urban

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
  




