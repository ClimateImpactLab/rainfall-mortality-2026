#========================================================================================#
#' Estimate precip responses using data from Carleton et al 2022
#'
#' Produces:
#'   - replicate "/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/1_estimation/1_ster/age_spec/Agespec_response_spec2.ster  
#'   - estimate new regressions 
#'      - without country interactions in the precip poly
#'      - with log of mortality rate as the dependent variable
#'      
#' How to run this code:
#'   - set working directory at the root of the repository
#========================================================================================#
packages = c("tidyr", "ggplot2", "dplyr", "magrittr", "readr", "glue", "scales", 
            "stringr", "parallel", "RColorBrewer", "MetBrewer", "fixest", "haven")

message(" ---- loading packages ---- ")
invisible(lapply(packages, function(pkg) {
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}))

rm(packages)
#========================================================================================#
# set paths
USER = Sys.getenv("USER")
source(glue("/project/cil/home_dirs/{USER}/repos/rainfall-mortality-2026/0_utils/paths.R"))

# load functions
source(glue("/project/cil/home_dirs/{USER}/repos/rainfall-mortality-2026/0_utils/functions.R"))

# set working directory
# setwd(glue("/project/cil/home_dirs/{USER}/rainfall-mortality-2026/"))
#========================================================================================#

# read data
mortality_data <- read_dta(glue(CARLETON_2022_DATA_DIR, 
                                "0_data_cleaning/3_final/global_mortality_panel.dta")) %>% 
  select(-contains("BEST"),
         -contains("Spline"),
         -contains("bins"),
         -contains("rcs"),
         -contains("cdd"), 
         -contains("hdd"), 
         -contains("UDEL"), 
         -contains("13"), 
         -contains("tmax"))

# prep data for regressions
source(glue(DIR_REPO_RAINFALL_MORTALITY, "/carleton2022_precip/prep_data.R"))

# more clean up
names(mortality_data) <- str_remove_all(names(mortality_data), "_GMFD")
mortality_data <- mortality_data %>%
  mutate(log_deathrate_w99 = log(deathrate_w99)) # create log of winsorised death rate 

# replicate Agespec_response_spec2.ster
agespec_response_spec2 <- fit_response(data = mortality_data, 
                                       tavg_order = 4, 
                                       prcp_order = 2,
                                       country_prcp = TRUE)
etable(agespec_response_spec2)

# estimate the above without adm0 interactions of precip poly
agespec_response_unint <- fit_response(data = mortality_data, 
                                       tavg_order = 4, 
                                       prcp_order = 2)
etable(agespec_response_unint)

# estimate the above without adm0 interactions of precip poly
agespec_response_log_deathrate <- fit_response(data = mortality_data, 
                                       lhs = "log_deathrate_w99",
                                       tavg_order = 4, 
                                       prcp_order = 2)
etable(agespec_response_log_deathrate)
