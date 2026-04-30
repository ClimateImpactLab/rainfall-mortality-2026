library(haven)
library(fixest)
library(dplyr)
library(stringr)

data_dir <- "/project/cil/battuta_shares/gcp/estimation/mortality/"
setwd("/home/tbearpark/")

# Load data, remove variables to make it smaller

df <- read_dta(file.path(data_dir, 
                         'release_2020/data/0_data_cleaning/3_final/',
                         'global_mortality_panel.dta')) %>% 
  select(-contains("BEST"),
         -contains("Spline"),
         -contains("bins"),
         -contains("rcs"),
         -contains("cdd|hdd"))
gc()

# Functions so we don't have to copy code

get_weights <- function(df){
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup), # convert to factor for feols
           adm0_code = as.factor(adm0_code)) # convert to factor for feols
  
}

fit_mod <- function(mortality_data, cleaning){
  if(cleaning == "old"){
    source("rainfall-mortality-2026/carleton2022_precip/prep_data.R", local=TRUE)
  }else if (cleaning == "fixed"){
    source("rainfall-mortality-2026/carleton2022_precip/prep_data_fix.R",local=TRUE)
  }else{
    stop("Not implemented")
  }
  mortality_data <- get_weights(mortality_data)
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
    cluster = ~adm1_code, # clustered SEs
    lean=TRUE # reduce size of output to make it less crashy
  )
  fit
}

# Check regression outputs
m0 <- fit_mod(df, "old")
gc()
m1 <- fit_mod(df, "fixed")
gc()
etable(m0, m1)

# Compare R2 - if it's the same its probably the same reg. 
# STATA OUTPUT: display "R-squared:        " %9.7f e(r2)
#               R-squared:        0.9873117

r2(m1, type = "r2") 

summary(m1)


