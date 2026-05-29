#========================================================================================#
# load packages
packages = c("tidyr", "ggplot2", "dplyr", "magrittr", "readr", "glue", "scales", 
             "purrr", "stringr", "parallel", "sf", "terra", "exactextractr")

message(" ---- loading packages ---- ")
invisible(lapply(packages, function(pkg) {
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}))

rm(packages)

#========================================================================================#

# set paths
USER = Sys.getenv("USER")
source(glue("/project/cil/home_dirs/{USER}/repos/rainfall-mortality-2026/0_utils/paths.R"))

#========================================================================================#

# function to load GHSL stacks
load_ghsl_stack <- function(raster_path, stack, na_flag = NULL) {
  
  # stack population and urbanization rasters and read them
  result <- list.files(raster_path, pattern = glue("GHS_{stack}.*\\.tif$"),
                       full.names = TRUE, recursive = TRUE) %>%
    sort() %>%
    rast()
  
  # set NoData flag if provided
  if (!is.null(na_flag)) NAflag(result) <- na_flag
  
  # clean column names
  years <- seq(1975, 2030, by = 5)
  names(result) <- glue("{stack}_{years}")
  
  return(result)
}

rast_path = "/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl/data/"
pop_stack <- load_ghsl_stack(rast_path, "POP", na_flag = -200)
smod_stack <- load_ghsl_stack(rast_path, "SMOD", na_flag = -200)

# function to extract data for all countries in carleton et al 2022
extract_ghsl <- function(shp_path, iso, shp_name, stack1, stack2) {
  
  # read shapefile
  if (iso == "MEX") {
    adm2_shp <- st_read(glue("{shp_path}/{iso}/Shapefile/harmonized/{shp_name}"))
  } else {
    adm2_shp <- st_read(glue("{shp_path}/{iso}/Shapefile/{shp_name}"))
  }
  
  # extract total population
  result_stack1  <- exact_extract(stack1, adm2_shp, "sum")
  
  # extract majority settlement type (most common SMOD class by area)
  result_stack2 <- exact_extract(stack2, adm2_shp, "majority")
  
  # extract urban share (population weighted share of urban population per polygon)
  years <- seq(1975, 2030, by = 5) # one layer at a time
  result_urban_share <- map(seq_along(years), function(i) {
    exact_extract(stack2[[i]], adm2_shp, function(values, coverage_frac, weights) {
      urban <- values >= 21 & !is.na(values) & values != 10
      (sum(weights[urban] * coverage_frac[urban], na.rm = TRUE) /
          sum(weights * coverage_frac, na.rm = TRUE)) * 100
    }, weights = stack1[[i]])
  }) %>%
    setNames(glue("urban_share_{years}")) %>%
    as_tibble()
  
  # result_urban_share <- map(seq_along(years), function(i) {
  #   exact_extract(stack2[[i]], adm2_shp, function(values, coverage_frac, weights) {
  #     valid <- !is.na(values) & values != 10
  #     urban <- valid & values >= 21
  #     denom <- sum(weights[valid] * coverage_frac[valid], na.rm = TRUE)
  #     if (denom == 0) return(NA)
  #     (sum(weights[urban] * coverage_frac[urban], na.rm = TRUE) / denom) * 100
  #   }, weights = stack1[[i]])
  # }) %>%
  #   setNames(glue("urban_share_{years}")) %>%
  #   as_tibble()
  
  # combine. not in shapefile for now
  adm2_shp %>%
    st_drop_geometry() %>%
    bind_cols(result_stack1) %>%
    bind_cols(result_stack2) %>%
    bind_cols(result_urban_share)
}

# list of countries: EU, BRA, CHL, CHN, FRA, JPN, MEX, USA
shp_input <- "/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/"
# lists of all ISO names and shapefile names 
iso_list <- c("EU", "BRA", "CHL", "CHN", "FRA", "JPN", "USA", "MEX")
shp_list <- c("NUTS2_RG_60M_2013_mortality.shp", "BRA_adm2.shp",
              "cl_comunas_geo_mortality_adm2.shp", "china00.shp",
              "FRA_adm2.shp", "JPN_adm1.shp", "tl_2016_us_county_mortality.shp",
              "boundaries_4795_IPUMS_MX_HSLAD_1990_2015.shp")

# apply the function
results <- map2(iso_list, shp_list, 
                ~extract_ghsl(shp_input, .x, .y, pop_stack, smod_stack))

# name the list by ISO for easy access
names(results) <- iso_list

#' check a few countries. they have different column names. 
#' select the same columns and standardize their names
results$BRA <- results$BRA %>%
  mutate(iso2 = "BRA") %>%
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>% 
  mutate(across(contains("ID"), as.character))

results$CHL <- results$CHL %>%
  rename(ID_1 = adm1_id, ID_2 = adm2_id) %>%
  mutate(iso2 = "CHL") %>%
  mutate(across(contains("ID"), as.character))

results$CHN <- results$CHN %>%
  rename(ID_1 = PROVGB, ID_2 = CNTYGB) %>%
  mutate(iso2 = "CHN") %>%
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

results$EU <- results$EU %>%
  mutate(ID_1 = str_sub(NUTS_ID, 1, 3),
         iso2 = "EU") %>% # NUTS_1 ID is first three characters from NUTS_2 ID
  rename(ID_2 = NUTS_ID) %>% 
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

results$FRA <- results$FRA %>%
  mutate(iso2 = "FRA") %>%
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

results$JPN <- results$JPN %>%
  mutate(ID_2 = NA_character_,
         iso2 = "JPN") %>% # mortality data for Japan is at ADM1 level
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

results$USA <- results$USA %>%
  mutate(iso2 = "USA") %>%
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

results$MEX <- results$MEX %>%
  mutate(ID_1 = str_sub(GEOID, 5, 6),
         iso2 = "MEX") %>% # NUTS_1 ID is first three characters from NUTS_2 ID
  rename(ID_2 = GEOID) %>% 
  select(iso2, ID_1, ID_2, starts_with("sum"), starts_with("majority"), starts_with("urban_share_")) %>%
  mutate(across(contains("ID"), as.character))

# combine the results
all_countries <- bind_rows(results)

# output cleaned data
write_csv(all_countries, glue(DATA_DIR, "/heterogeniety_data/ghsl/cleaned/ghsl_pop_landuse_popshare.csv"))

#------------------ TEST CODE --------------------
# # test on one year
# pop75 <- rast("/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl/data/GHS_POP_E1975_GLOBE_R2023A_4326_30ss_V1_0/GHS_POP_E1975_GLOBE_R2023A_4326_30ss_V1_0.tif")

# # stack population and urbanization rasters
# pop_files  <- list.files("/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl/data/", 
#                          pattern = "GHS_POP.*\\.tif$",  
#                          full.names = TRUE, 
#                          recursive = TRUE) %>% sort() # arrange file names chronologically
# smod_files <- list.files("/project/cil/gcp/estimation/rainfall-mortality/heterogeniety_data/ghsl/data/",
#                          pattern = "GHS_SMOD.*\\.tif$", 
#                          full.names = TRUE, 
#                          recursive = TRUE) %>% sort() # arrange file names chronologically
# # read the rasters
# pop_stack  <- rast(pop_files)
# smod_stack <- rast(smod_files)
# 
# # clean column names
# years <- seq(1975, 2030, by = 5)
# names(pop_stack)  <- glue("pop_{years}")
# names(smod_stack) <- glue("smod_{years}")

# # test on one country
# us_county_shp <- st_read("/project/cil/norgay/Global_ACP/MORTALITY/Replication_2018/2_Data/Raw/Countries/USA/Shapefile/tl_2016_us_county_mortality.shp")
# 
# result_pop <- exact_extract(pop_stack, us_county_shp, "sum")
# result_smod <- exact_extract(smod_stack, us_county_shp, "weighted_mean", weights = pop_stack)
# 
# us_pop <- us_county_shp %>%
#   st_drop_geometry() %>%  # drop the geometry column
#   bind_cols(result_pop) %>%
#   bind_cols(result_smod)


