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
                         log_mort = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup",
                                "adm0_code^year^agegroup"),
                         weights = ~weight,
                         cluster = ~adm1_code,
                         ...) {
  
  # build rhs
  rhs <- character() # initialize an empty character vector to hold all terms
  
  # create the temperature polynomial only when tavg order is more than zero
  if (tavg_order > 0) {
    rhs <- c(rhs, paste0("i(agegroup, tavg_poly_", seq_len(tavg_order), ")"))
  }
  
  # create the precipitation polynomial only when precip order is more than zero
  if (prcp_order > 0) {
    # create different precip terms based on if country_prcp is TRUE/FALSE
    rhs <- c(rhs, if (country_prcp){
      paste0("adm0_code:prcp_poly_", seq_len(prcp_order), ":agegroup")
      } else {
        paste0("i(agegroup, prcp_poly_", seq_len(prcp_order), ")")
        })
  }
  
  # create the formula for feols
  f <- as.formula(sprintf("%s ~ %s | %s",
                          lhs,
                          paste(rhs, collapse = " + "), # combine rhs, separated by +
                          paste(fe, collapse = " + "))) # combine fixed effects, separated by +
  
  # run the regression
  if (log_mort) {
    fepois(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
  } else {
    feols(f, data = data, weights = weights, cluster = cluster, lean = TRUE, ...)
  }
}

#' Coefficient-name template that matches what `fit_response` produces.
#' Picks the right naming convention based on `country`. 
#' country: TRUE -> no pattern in names due to triple interaction 
#'          FALSE -> names in consistent pattern
#' prefix: prcp_poly_ or tavg_poly_
make_coef_names <- function(prefix, country = FALSE, fit = NULL) {

  if (country) {
    if (is.null(fit)) {
      stop("country = TRUE needs `fit` to look up coefficient names from the fitted model")
    }
    cn <- names(coef(fit)) # collect feols coefficient names
    cn_tok <- strsplit(cn, ":", fixed = TRUE) # split them by colon
    
    # a function of group (g) and polynomial (k) order that returns coefficient name
    function(g, k) {
      # build the set of expected tokens in the coefficient name
      want <- c(paste0("adm0_code", g$adm0_code),
                paste0("agegroup",  g$agegroup),
                paste0(prefix, k))
      # check whether there's a matching token and find the indices where the match is true
      hits <- which(vapply(cn_tok, setequal, logical(1), want))
      # ensure that the coefficient name is returned only in the case of one match
      if (length(hits) == 1) cn[hits] else NA_character_
    }
  } else {
    function(g, k) sprintf("agegroup::%s:%s%d", g$agegroup, prefix, k)
  }
}

#' Polynomial response f(x) − f(x_ref) with delta-method SE. 
#' b: coefficients
#' V: variance-covariance matrix
#' x: temperature or precipitation values
#' coef_names: coefficient names come from calling make_coef_names before this 
#'             function inside build_response function
#' x_ref: reference precipitation (0mm) or temperature (27C)
poly_response <- function(b, V, x, coef_names, x_ref = 0) {
  
  P <- length(coef_names) # number of coefficient names = polynomial order
  xpow <- outer(x, 1:P, `^`) - matrix(x_ref^(1:P), nrow = length(x), ncol = P,
                                      byrow = TRUE) # raise each x value to power 1 to P and subtract reference values from it
  Vsub <- V[coef_names, coef_names, drop = FALSE] #  extract variance-covariance matrix for the relevant coefficients
  dy <- as.numeric(xpow %*% b[coef_names]) # predicted response
  se <- sqrt(rowSums((xpow %*% Vsub) * xpow)) # sqrt(x' V x) for each point 

  # return a tidyverse dataframe
  tibble(x = x, dy = dy, se = se, lo = dy - 1.96*se, hi = dy + 1.96*se)
}

#' Build response curves across grouping combinations, relative to x_ref.
#' fit: name of the fit
#' x: temperature or precipitation values
#' poly_order: order of the temperature or precipitation polynomial
#' groups: grouping variable e.g. agegroup, adm0_code etc
#' key: dictionary of coefficient names from make_coef_names function
#' x_ref: reference precipitation or temperature
#' id: which of temperature or precipitation
build_response <- function(fit, x, poly_order, groups, key,
                           x_ref = 0, id = "") {
  # extract coefficients, variance-covariance matrix, and coefficient names from the fitted model upfront
  b <- coef(fit); V <- vcov(fit); cn <- names(b)
  
  # use make_coef_names and poly_response to output response data
  out <- groups %>%
    mutate(.gid = row_number()) %>% # assign numeric group ID to each row
    group_by(.gid) %>%
    # iterate over each group
    group_modify(~ {
      # apply make_coef_names to all terms of the current group
      nms <- vapply(seq_len(poly_order),
                    function(k) key(.x, k), character(1))
      # return NA values if coefficient name does not exist
      if (!all(nms %in% cn)) {
        return(tibble(x = x, dy = NA_real_, se = NA_real_,
                      lo = NA_real_, hi = NA_real_))
      }
      # compute response curve for each x value
      poly_response(b, V, x, nms, x_ref = x_ref)
    }) %>%
    ungroup() %>%
    # reattach original group columns
    left_join(mutate(groups, .gid = row_number()), by = ".gid") %>%
    select(-.gid) %>%
    mutate(id = id)
  
  # report dropped cells
  dropped <- out %>%
    filter(is.na(dy)) %>%
    distinct(across(all_of(names(groups))))
  if (nrow(dropped) > 0) {
    message("build_response: dropped ", nrow(dropped),
            " cell(s) with no estimated coefficients:")
    message(paste(utils::capture.output(print(dropped)), collapse = "\n"))
  }
  
  # remove missing y_hat values
  out %>% filter(!is.na(dy))
}
