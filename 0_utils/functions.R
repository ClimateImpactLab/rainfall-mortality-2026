#========================================================================================#
#' General purpose functions that will be used throughout the project
#'
#========================================================================================#

#' function to generate weights and convert agegroup to factor
#' for regressions using data from Carleton et al 2022.
#' Factor conversion of the precip-interaction variable (if any) is handled
#' inside `fit_response`, since that's where the choice of variable lives.
get_weights <- function(df){
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(weight = population/tot_pop, # generate weights
           agegroup = as.factor(agegroup)) # convert to factor for feols
}

#' Fit a Carleton-style polynomial regression.
#' tavg_order / prcp_order: 0 to skip that block, otherwise the polynomial order.
#' interact_var: NULL  -> prcp_poly_k × agegroup only
#'               "col" -> col × prcp_poly_k × agegroup interactions, where
#'                       "col" is any categorical column in `data`
#'                       (e.g. "adm0_code", "adm1_id", "climate_zone").
#' suffix: suffix of the climate variable based on the climate produce 
#'         e.g. GMFD = "", ERA5-Land = "ERA5LAND" etc.
#' Note: `fe` defaults assume a country-style design. When changing
#' `interact_var`, you'll usually want to pass an `fe` that matches the new
#' grouping (e.g. drop `adm0_code^year^agegroup` for adm1-level interactions).
fit_response <- function(data,
                         lhs = "deathrate_w99",
                         tavg_order,
                         prcp_order,
                         interact_var = NULL,
                         log_mort = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup", "adm0_code^year^agegroup"),
                         weights = NULL,
                         cluster = ~adm1_code,
                         suffix = "",
                         ...) {

  # ensure the interaction variable is a factor so feols treats it as categorical
  if (!is.null(interact_var)) {
    if (!interact_var %in% names(data)) {
      stop("interact_var '", interact_var, "' not found in data")
    }
    if (!is.factor(data[[interact_var]])) {
      data[[interact_var]] <- as.factor(data[[interact_var]])
    }
  }

  # build rhs
  rhs <- character() # initialize an empty character vector to hold all terms

  # create the temperature polynomial only when tavg order is more than zero
  if (tavg_order > 0) {
    rhs <- c(rhs, paste0("i(agegroup, tavg_poly_", seq_len(tavg_order), suffix, ")"))
  }

  # create the precipitation polynomial only when precip order is more than zero
  if (prcp_order > 0) {
    # create different precip terms based on whether interact_var is set
    rhs <- c(rhs, if (!is.null(interact_var)) {
      paste0(interact_var, ":prcp_poly_", seq_len(prcp_order), suffix, ":agegroup")
    } else {
      paste0("i(agegroup, prcp_poly_", seq_len(prcp_order), suffix, ")")
    })
  }
  
  # create the formula for feols
  f <- as.formula(sprintf("%s ~ %s | %s",
                          lhs,
                          paste(rhs, collapse = " + "), # combine rhs, separated by +
                          paste(fe, collapse = " + "))) # combine fixed effects, separated by +
  
  # print the regression equation
  print(paste0("formula: ", deparse(f)))
  
  # conditionally add regression weights
  args <- list(f, data = data, cluster = cluster, lean = TRUE, ...) 
  if (!is.null(weights)) args$weights <- weights
  
  # run regression
  if (log_mort) {
    print("running fepois regression")
    do.call(fepois, args)
  } else {
    print("running feols regression")
    do.call(feols, args)
  }
}

#' Coefficient-name template that matches what `fit_response` produces.
#' Picks the right naming convention based on `interact_var`.
#' interact_var: NULL  -> consistent `agegroup::X:prefixK` pattern
#'               "col" -> token-match against the fitted coefficient names,
#'                       expecting tokens like "<col><level>", "agegroup<lvl>"
#'                       and "<prefix><k>". The `groups` tibble passed to
#'                       `build_response` must contain a column named `col`.
#' prefix: prcp_poly_ or tavg_poly_
#' suffix: suffix of the climate variable based on the climate produce 
#'         e.g. GMFD = "", ERA5-Land = "ERA5LAND" etc. 
make_coef_names <- function(prefix, interact_var = NULL, fit = NULL, suffix = "") {

  if (!is.null(interact_var)) {
    if (is.null(fit)) {
      stop("interact_var requires `fit` to look up coefficient names from the fitted model")
    }
    cn <- names(coef(fit)) # collect feols coefficient names
    cn_tok <- strsplit(cn, ":", fixed = TRUE) # split them by colon

    # a function of group (g) and polynomial (k) order that returns coefficient name
    function(g, k) {
      # build the set of expected tokens in the coefficient name
      want <- c(paste0(interact_var, g[[interact_var]]),
                paste0("agegroup",  g$agegroup),
                paste0(prefix, k, suffix))
      # check whether there's a matching token and find the indices where the match is true
      hits <- which(vapply(cn_tok, setequal, logical(1), want))
      # ensure that the coefficient name is returned only in the case of one match
      if (length(hits) == 1) cn[hits] else NA_character_
    }
  } else {
    function(g, k) sprintf("agegroup::%s:%s%d%s", g$agegroup, prefix, k, suffix)
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
    dplyr::select(-.gid) %>%
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

#' Plot response
#' 
plot_response <- function(rf_data, color = "agegroup", facet = NULL,
                          xlab = NULL, ylab = "Δ outcome (vs x = ref)",
                          p_title = NULL, scales='fixed') {
  
  color_palette <- met.brewer("Hokusai3", n = 3)
  
  p <- ggplot(rf_data, aes(x, dy, color = .data[[color]], fill = .data[[color]])) +
    geom_hline(yintercept=0, linewidth = 1, color="black", alpha=0.1)+
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.3, color = NA) +
    geom_line(linewidth = 1) +
    scale_color_manual(values = color_palette) +
    scale_fill_manual(values = color_palette) +
    labs(x = xlab, y = ylab, title = p_title) +
    theme_classic() +
    theme(legend.key.spacing.y = unit(0.3, "cm") ,
          legend.key.width = unit(1.5, "cm"),
          axis.line = element_line(color = "black", linewidth = 1),
          axis.text = element_text(size = 10),
          axis.title = element_text(size = 14),
          plot.title = element_text(size = 16, face = "bold"),
          strip.text = element_text(size = 12)) +
  guides(fill = "none")
  if (!is.null(facet)) p <- p + facet_wrap(facet, ncol = 5, scales = scales)
  p
}
