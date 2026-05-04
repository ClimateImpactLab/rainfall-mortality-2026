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
mortality_data <- get_weights(mortality_data) %>%
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
# generate the response functions
agespec_response_unint_rf <- build_response(agespec_response_unint, 
                                            x = 0:300, poly_order = 2,
                                            groups = tibble(agegroup = levels(mortality_data$agegroup)),
                                            key = make_coef_names("prcp_poly_", country = FALSE), 
                                            id = "Precip")

# estimate the above without adm0 interactions of precip poly
agespec_response_log_deathrate <- fit_response(data = mortality_data,
                                               log_mort = TRUE,
                                               tavg_order = 4, 
                                               prcp_order = 2)
# generate the response functions
agespec_response_log_deathrate_rf <- build_response(agespec_response_log_deathrate, 
                                                    x = 0:300, poly_order = 2,
                                                    groups = tibble(agegroup = levels(mortality_data$agegroup)),
                                                    key = make_coef_names("prcp_poly_", country = FALSE), 
                                                    id = "Precip")

# look at the coefficients together
etable(agespec_response_unint, agespec_response_log_deathrate)


# plot
agespec_response_unint_rf <- agespec_response_unint_rf %>%
  # convert agegroup to character
  mutate(`Age Group` = case_when(as.character(agegroup) == "1" ~ "0 to 4",
                                 as.character(agegroup) == "2" ~ "5 to 64",
                                 as.character(agegroup) == "3" ~ "65 & above"),
         `Age Group` = factor(`Age Group`, levels = c("0 to 4", "5 to 64", "65 & above")))

agespec_response_log_deathrate_rf <- agespec_response_log_deathrate_rf %>%
  mutate(`Age Group` = case_when(as.character(agegroup) == "1" ~ "0 to 4",
                                 as.character(agegroup) == "2" ~ "5 to 64",
                                 as.character(agegroup) == "3" ~ "65 & above"),
         `Age Group` = factor(`Age Group`, levels = c("0 to 4", "5 to 64", "65 & above")))
