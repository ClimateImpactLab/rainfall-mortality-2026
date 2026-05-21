#packages = c("tidyr", "ggplot2", "dplyr", "readr", "glue", "scales", "stringr", "fixest", "haven")

# Minimal package loading
library(dplyr)
library(fixest)
library(ggplot2)
library(readr)
library(RColorBrewer)
library(MetBrewer)

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
df <- left_join(mortality_data, urban_long, by = c("iso2", "adm1_id"="ID_1","adm2_id"="ID_2", "year_5s" = "year"))

# EDA PLOTS ---------------------------
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

# should add some maps and time series...

# Regression ---------------------------
# Cut urbanisation into binary variable: 
df <- df %>%
  mutate(urban =if_else(weighted_mean.SMOD_1975.POP_1975 > 15, 1, 0)
  )




