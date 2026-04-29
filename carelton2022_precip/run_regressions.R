#========================================================================================#
#' Estimate precip responses using data from Carleton et al 2022
#'
#' Created By: Nishka Sharma
#' Date Created: Apr 24 2025
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
             "parallel", "RColorBrewer", "MetBrewer", "fixest", "haven")

message(" ---- loading packages ---- ")
invisible(lapply(packages, function(pkg) {
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}))

rm(packages)
#========================================================================================#
# read data
mortality_data <- read_dta("/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/3_final/global_mortality_panel.dta")

# prep data for regressions
source("carelton2022_precip/prep_data.R")

# replicate Agespec_response_spec2.ster
mortality_data <- mortality_data %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup), # convert to factor for feols
           adm0_code = as.factor(adm0_code)) # convert to factor for feols

# fixed effects regression
fit <- feols(
  deathrate_w99 ~ 
    tavg_poly_1_GMFD:agegroup + 
    tavg_poly_2_GMFD:agegroup + 
    tavg_poly_3_GMFD:agegroup + 
    tavg_poly_4_GMFD:agegroup + 
    adm0_code:prcp_poly_1_GMFD:agegroup + 
    adm0_code:prcp_poly_2_GMFD:agegroup |
    adm2_code^CHN_ts^agegroup + # fixed effects
    adm0_code^year^agegroup, # fixed effects
  data = mortality_data,
  weights = ~weight, # analytic weights
  cluster = ~adm1_code # clustered SEs
)

# extract residuals
# df$e_hat <- residuals(fit)

summary(fit)
# etable(fit, file = "output/tables/Agespec_response_spec2_R.tex")

