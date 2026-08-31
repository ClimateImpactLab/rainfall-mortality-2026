# ==============================================================================
# functions.R
#
# Common regression and response-curve code
#
# The regression scripts call these functions after preparing the analysis
# panel in `2_analysis/regressions/00_prep_analysis_panel.R`
#
# `fit_response()` runs the fixest regression
# `build_response()` turns fitted polynomial coefficients into response-curve data
# `plot_response()` is an older plotting function
# Only scripts in `2_analysis/archive` use it
# ==============================================================================


# -----------------------------
# Regression weights
# -----------------------------

# Use population weights within each year and age group
# Convert `agegroup` to a factor because the regressions interact climate with age
get_weights <- function(df) {
  df %>%
    group_by(year, agegroup) %>%
    mutate(tot_pop = sum(population, na.rm = TRUE)) %>%
    ungroup() %>%
    mutate(
      weight = population / tot_pop,
      agegroup = as.factor(agegroup)
    )
}


# -----------------------------
# Estimate one response regression
# -----------------------------

# `tavg_order` and `prcp_order` are the temperature and rainfall polynomial orders
# Use 0 if the regression should not include that climate variable
# `interact_var` is used for heterogeneity regressions
# For example, urban-share regressions estimate separate rainfall curves by
# age group and urban-share group
# `controls` adds extra regression terms, such as wind controls
# The default fixed effects are used by the main response regressions
fit_response <- function(data,
                         lhs = "deathrate_w99",
                         tavg_order,
                         prcp_order,
                         interact_var = NULL,
                         log_mort = FALSE,
                         fe = c("adm2_code^CHN_ts^agegroup",
                                "adm0_code^year^agegroup"),
                         controls = character(),
                         weights = ~weight,
                         cluster = ~adm1_code,
                         ...) {
  
  # Heterogeneity groups need to be factors before fixest builds interactions
  if (!is.null(interact_var)) {
    if (!interact_var %in% names(data)) {
      stop("interact_var '", interact_var, "' not found in data")
    }
    if (!is.factor(data[[interact_var]])) {
      data[[interact_var]] <- as.factor(data[[interact_var]])
    }
  }
  
  # Build the regression RHS
  rhs <- character()
  
  # Temperature terms by age group
  if (tavg_order > 0) {
    rhs <- c(rhs, paste0("i(agegroup, tavg_poly_", seq_len(tavg_order), ")"))
  }
  
  # Rainfall terms by age group
  # Heterogeneity regressions add one more grouping variable
  if (prcp_order > 0) {
    if (!is.null(interact_var)) {
      prcp_terms <- paste0(interact_var, ":prcp_poly_", seq_len(prcp_order), ":agegroup")
    } else {
      prcp_terms <- paste0("i(agegroup, prcp_poly_", seq_len(prcp_order), ")")
    }
    
    rhs <- c(rhs, prcp_terms)
  }
  
  rhs <- c(rhs, controls)
  
  # In fixest formulas, fixed effects come after the vertical bar
  f <- as.formula(sprintf("%s ~ %s | %s",
                          lhs,
                          paste(rhs, collapse = " + "),
                          paste(fe, collapse = " + ")))
  
  # Run the death-rate levels model or the Poisson/log-link model
  if (log_mort) {
    fepois(f, data = data, weights = weights, cluster = cluster, lean = FALSE, ...)
  } else {
    feols(f, data = data, weights = weights, cluster = cluster, lean = FALSE, ...)
  }
}


# -------------------------------------
# Coefficient names for response curves
# -------------------------------------

# Find the coefficient name for each polynomial term in response curve
# Main age-only regressions have predictable fixest names
# Heterogeneity regressions need names read from the fitted model
# The function returned below takes one response-curve group and one polynomial
# term number, then returns the matching coefficient name
make_coef_names <- function(prefix, interact_var = NULL, fit = NULL) {
  
  if (!is.null(interact_var)) {
    if (is.null(fit)) {
      stop("Pass `fit` when using `interact_var`")
    }
    coef_names <- names(coef(fit))
    coef_parts <- strsplit(coef_names, ":", fixed = TRUE)
    
    function(group_row, poly_term) {
      want <- c(
        paste0(interact_var, group_row[[interact_var]]),
        paste0("agegroup", group_row$agegroup),
        paste0(prefix, poly_term)
      )
      
      match <- logical(length(coef_parts))
      for (i in seq_along(coef_parts)) {
        match[[i]] <- setequal(coef_parts[[i]], want)
      }
      
      hits <- which(match)
      if (length(hits) == 1) coef_names[hits] else NA_character_
    }
  } else {
    function(group_row, poly_term) {
      sprintf("agegroup::%s:%s%d", group_row$agegroup, prefix, poly_term)
    }
  }
}


# -----------------------------
# Response curve values
# -----------------------------

# Calculate f(x) - f(x_ref) from one fitted polynomial
# Standard errors use the delta method
poly_response <- function(b, V, x, coef_names, x_ref = 0) {
  coefficients <- b
  vcov_matrix <- V
  polynomial_order <- length(coef_names)
  
  # Powers of x, minus the same powers at the reference value
  x_power <- outer(x, 1:polynomial_order, `^`) - matrix(
    x_ref^(1:polynomial_order),
    nrow = length(x),
    ncol = polynomial_order,
    byrow = TRUE
  )
  
  # Variance matrix for the polynomial coefficients only
  vcov_poly <- vcov_matrix[coef_names, coef_names, drop = FALSE]
  
  dy <- as.numeric(x_power %*% coefficients[coef_names])
  se <- sqrt(rowSums((x_power %*% vcov_poly) * x_power))
  
  tibble(x = x, dy = dy, se = se, lo = dy - 1.96 * se, hi = dy + 1.96 * se)
}


# Build one response curve for each row of `groups`
# Main results have one row per age group
# Heterogeneity results also include the group variable, like urban share
build_response <- function(fit, x, poly_order, groups, key,
                           x_ref = 0, id = "", vcov_cluster = NULL,
                           vcov_fix = FALSE) {
  coefficients <- coef(fit)
  vcov_matrix <- if (is.null(vcov_cluster)) {
    vcov(fit, vcov_fix = vcov_fix)
  } else {
    vcov(fit, cluster = vcov_cluster, vcov_fix = vcov_fix)
  }
  fitted_coef_names <- names(coefficients)
  
  curves <- list()
  dropped <- list()
  
  for (i in seq_len(nrow(groups))) {
    group_i <- groups[i, , drop = FALSE]
    
    # Coefficients needed for this curve
    curve_coef_names <- character(poly_order)
    for (k in seq_len(poly_order)) {
      curve_coef_names[[k]] <- key(group_i, k)
    }
    
    # Skip groups with missing polynomial coefficients
    if (!all(curve_coef_names %in% fitted_coef_names)) {
      dropped[[length(dropped) + 1]] <- group_i
      next
    }
    
    curves[[length(curves) + 1]] <- bind_cols(
      group_i,
      poly_response(coefficients, vcov_matrix, x, curve_coef_names, x_ref = x_ref)
    )
  }
  
  if (length(dropped) > 0) {
    dropped_df <- bind_rows(dropped)
    message("build_response: dropped ", nrow(dropped_df),
            " cell(s) with no estimated coefficients:")
    message(paste(utils::capture.output(print(dropped_df)), collapse = "\n"))
  }
  
  bind_rows(curves) %>%
    mutate(id = id)
}


# -----------------------------
# Older response plot function
# -----------------------------

# Only used by scripts in `2_analysis/archive`
plot_response <- function(rf_data, color = "agegroup", facet = NULL,
                          xlab = NULL, ylab = "Δ outcome (vs x = ref)",
                          scales = "fixed") {
  
  color_palette <- met.brewer("Hokusai3", n = 3)
  
  p <- ggplot(rf_data, aes(x, dy, color = .data[[color]], fill = .data[[color]])) +
    geom_hline(yintercept = 0, linewidth = 1, color = "black", alpha = 0.1) +
    geom_ribbon(aes(ymin = lo, ymax = hi), alpha = 0.3, color = NA) +
    geom_line(linewidth = 1) +
    scale_color_manual(values = color_palette) +
    scale_fill_manual(values = color_palette) +
    labs(x = xlab, y = ylab) +
    theme_classic() +
    theme(
      legend.key.spacing.y = unit(0.3, "cm"),
      legend.key.width = unit(1.5, "cm"),
      axis.line = element_line(color = "black", linewidth = 1),
      axis.text = element_text(size = 10),
      axis.title = element_text(size = 14),
      plot.title = element_text(size = 16, face = "bold"),
      strip.text = element_text(size = 12)
    ) +
    guides(fill = "none")
  
  if (!is.null(facet)) p <- p + facet_wrap(facet, ncol = 5, scales = scales)
  
  p
}
