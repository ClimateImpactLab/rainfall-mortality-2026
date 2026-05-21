#packages = c("tidyr", "ggplot2", "dplyr", "readr", "glue", "scales", "stringr", "fixest", "haven")

# Minimal package loading
library(dplyr)
library(fixest)
library(ggplot2)
library(readr)

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

# Load admin urbanisation data
urban <- paste0(DATA_DIR, 
                "/heterogeniety_data/ghsl/cleaned/", 
                "ghsl_pop_weighted.csv") %>% 
  read_csv()

# Join
df <- left_join(mortality_data, urban, by = c("adm1_id"="ID_1","adm2_id"="ID_2"))

# EDA PLOTS ---------------------------
ggplot() + geom_histogram(data = urban, aes(x = weighted_mean.SMOD_1975.POP_1975))

# should add some maps and time series...

# Regression ---------------------------
# Cut urbanisation into binary variable: 
df <- df %>%
  mutate(urban =if_else(weighted_mean.SMOD_1975.POP_1975 > 15, 1, 0)
  )




