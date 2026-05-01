#========================================================================================#
#' General purpose functions that will be used throughout the project
#'
#========================================================================================#

#' function to generate weights and convert interacted variables to factors 
#' for regressions using data from Carleton et al 2022.
get_weights <- function(df){
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup), # convert to factor for feols
           adm0_code = as.factor(adm0_code)) # convert to factor for feols
}

#' Fit a Carleton-style polynomial regression.
#' tavg_order / prcp_order: 0 to skip that block, otherwise the polynomial order.
#' country_prcp: TRUE -> adm0_code × prcp_poly_k × agegroup interactions
#'               FALSE -> prcp_poly_k × agegroup only
fit_response <- function(data,
                         lhs = "deathrate_w99",
                         tavg_order,
                         prcp_order,
                         country_prcp = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup",
                                "adm0_code^year^agegroup"),
                         weights = ~weight,
                         cluster = ~adm1_code,
                         ...) {
  
  # get weights
  data <- get_weights(data)
  
  # build rhs
  rhs <- character() # initialize an empty character vector to hold all terms
  
  # create the temperature polynomial only when tavg order is more than zero
  if (tavg_order > 0) {
    rhs <- c(rhs, paste0("tavg_poly_", seq_len(tavg_order), ":agegroup"))
  }
  
  # create the temperature polynomial only when tavg order is more than zero
  if (prcp_order > 0) {
    # create different precip terms based on if country_prcp is TRUE/FALSE
    if (country_prcp) {
      rhs <- c(rhs, paste0("adm0_code:prcp_poly_", seq_len(prcp_order), ":agegroup"))
    } else {
      rhs <- c(rhs, paste0("prcp_poly_", seq_len(prcp_order), ":agegroup"))
    }
  }
  
  # combine rhs, separated by +
  rhs <- paste(rhs, collapse = " + ")
  # combine fixed effects, separated by +
  fe <- paste(fe, collapse = " + ")
  
  # create the formula for feols
  f <- as.formula(paste(lhs, "~", rhs, "|", fe))
  
  # run the regression
  feols(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
}


