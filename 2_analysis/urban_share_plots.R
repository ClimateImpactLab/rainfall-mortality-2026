# Minimal package loading
library(dplyr)
library(tidyr)
library(ggplot2)
library(readr)
library(RColorBrewer)
library(MetBrewer)
library(stringr)
theme_set(theme_classic())

# set paths
USER = Sys.getenv("USER")
setwd(this.path::this.dir())
source("../0_utils/paths.R")
source("../0_utils/functions.R")

# LOAD DATA ---------------------------
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

# EDA PLOTS ---------------------------
## histograms ---------------------------
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
}

## maps ---------------------------
# mapping libraries
library(sf)
library(purrr)
library(glue)

# read shapefile function
read_shp <- function(shp_path, iso, shp_name) {
  
  # read shapefile
  if (iso == "MEX") {
    adm2_shp <- st_read(glue("{shp_path}/{iso}/Shapefile/harmonized/{shp_name}"))
  } else {
    adm2_shp <- st_read(glue("{shp_path}/{iso}/Shapefile/{shp_name}"))
  }
}

shp_input <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/"
iso_list <- c("EU", "BRA", "CHL", "CHN", "FRA", "JPN", "USA", "MEX")
shp_list <- c("NUTS2_RG_60M_2013_mortality.shp", "BRA_adm2.shp",
              "cl_comunas_geo_mortality_adm2.shp", "china00.shp",
              "FRA_adm2.shp", "JPN_adm1.shp", "tl_2016_us_county_mortality.shp",
              "boundaries_4795_IPUMS_MX_HSLAD_1990_2015.shp")

shapefiles <- map2(iso_list, shp_list, 
                   ~read_shp(shp_input, .x, .y))

names(shapefiles) <- iso_list

# standardize column names and keep iso, adm1 and amd2 ID 
shapefiles$BRA <- shapefiles$BRA %>%
  mutate(iso2 = "BRA") %>%
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character)) 

shapefiles$CHL <- shapefiles$CHL %>%
  rename(ID_1 = adm1_id, ID_2 = adm2_id) %>%
  mutate(iso2 = "CHL") %>%
  mutate(across(contains("ID"), as.character))

shapefiles$CHN <- shapefiles$CHN %>%
  rename(ID_1 = PROVGB, ID_2 = CNTYGB) %>%
  mutate(iso2 = "CHN") %>%
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

shapefiles$EU <- shapefiles$EU %>%
  mutate(ID_1 = str_sub(NUTS_ID, 1, 3),
         iso2 = "EU") %>% # NUTS_1 ID is first three characters from NUTS_2 ID
  rename(ID_2 = NUTS_ID) %>% 
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

shapefiles$FRA <- shapefiles$FRA %>%
  mutate(iso2 = "FRA") %>%
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

shapefiles$JPN <- shapefiles$JPN %>%
  mutate(ID_2 = NA_character_,
         iso2 = "JPN") %>% # mortality data for Japan is at ADM1 level
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

shapefiles$USA <- shapefiles$USA %>%
  mutate(iso2 = "USA") %>%
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

shapefiles$MEX <- shapefiles$MEX %>%
  mutate(ID_1 = str_sub(GEOID, 5, 6),
         iso2 = "MEX") %>% # NUTS_1 ID is first three characters from NUTS_2 ID
  rename(ID_2 = GEOID) %>% 
  select(iso2, ID_1, ID_2) %>%
  mutate(across(contains("ID"), as.character))

all_countries <- bind_rows(shapefiles)

# plot
urban_map_df <- left_join(urban_long, all_countries, by = c("iso2", "ID_1", "ID_2"))

country_plots <- map(unique(urban_map_df$iso2), function(iso) {
  p <- urban_map_df %>%
    filter(iso2 == iso,
           year %in% seq(1980, 2030, by = 10)) %>%
    st_as_sf() %>%
    mutate(urban_decile = cut(urban_share, 
                              breaks = seq(0, 100, by = 10), 
                              include.lowest = TRUE)) %>%
    ggplot() +
    facet_wrap(~year, nrow = 1) +
    geom_sf(aes(fill = urban_decile), color = "black", lwd = 0.03) +
    scale_fill_manual(values = met.brewer("Hokusai3", 10)) +
    labs(title = iso, fill = "percent range") +
    theme_minimal() +
    theme(strip.text = element_text(face = "bold", size = 14))
  
  # restrict USA and EU to mainland
  if (iso == "USA") { 
    p <- p + coord_sf(xlim = c(-125, -60), ylim = c(20, 50), 
                      expand = FALSE)
  } else if (iso == "EU") {
    p <- p + coord_sf(xlim = c(-30, 50), ylim = c(20, 80), 
                      expand = FALSE)
  } else {
    p <- p + coord_sf(lims_method = "geometry_bbox")
  }
  
  p
})

walk2(country_plots, unique(urban_map_df$iso2), function(plot, iso) {
  ggsave(glue("{DIR_FIGURE}/ghsl/map_urban_pop_{iso}.png"), plot, width = 21, height = 6)
})
