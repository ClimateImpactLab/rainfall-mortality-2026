# Minimal package loading
library(dplyr)
library(tidyr)
library(readr)
library(stringr)
library(purrr)
library(glue)
library(arrow)

# set paths. making them less user dependent
USER = Sys.getenv("USER")
setwd(this.path::this.dir())
source("../../../0_utils/paths.R")
source("../../../0_utils/functions.R")
source("../../../0_utils/load_mortality_data.R")

# LOAD DATA ---------------------------
mortality_data <- load_mortality_data(CARLETON_2022_DATA_DIR, load_cleaned = TRUE,
                          cache_path = file.path(DATA_DIR, "mortality", 
                                                 "cleaned", "mortality_clean.parquet"))

# prep mortality for merge with GHSL data
mortality_data <- mortality_data %>%
  mutate(year_5s = round(year / 5) * 5, # column for every fifth year like in GHSL data
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

# write merged data
write_csv(df, file.path(DATA_DIR, "mortality", "merge", "ghsl_mortality_merged.csv"))
