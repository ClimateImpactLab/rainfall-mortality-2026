#========================================================================================#
#' Estimate precip-mortality response heterogeneity by adm2 precipitation climate.
#'
#' Each adm2 unit is assigned to a tercile of its long-run mean precipitation
#' (computed from the regression sample). The precip polynomial is then fully
#' interacted with the tercile factor and agegroup in a single regression, so
#' tercile differences can be tested directly off one covariance matrix.
#'
#' Produces:
#'   - agespec_response_het_precip:    fitted feols object
#'   - agespec_response_het_precip_rf: response curves by (tercile, agegroup)
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

# prep data for regressions (sample filters, adm codes, winsorisation)
source(glue(DIR_REPO_RAINFALL_MORTALITY, "/carleton2022_precip/prep_data.R"))

# more clean up
names(mortality_data) <- str_remove_all(names(mortality_data), "_GMFD")
mortality_data <- get_weights(mortality_data)

#========================================================================================#
# Assign each adm2 to a tercile of its long-run mean precipitation, computed
# over the regression sample. ntile is unweighted across adm2 units (one
# vote per unit on climate), so tercile cuts are not driven by population.
adm2_climate <- mortality_data %>%
  distinct(adm2_code, year, prcp_poly_1) %>%   # one row per adm2-year
  group_by(adm2_code) %>%
  summarise(prcp_climate = mean(prcp_poly_1, na.rm = TRUE), .groups = "drop") %>%
  mutate(prcp_tercile = as.factor(ntile(prcp_climate, 3)))

mortality_data <- mortality_data %>%
  left_join(adm2_climate, by = "adm2_code")

#========================================================================================#
# Fit the heterogeneity model: prcp_tercile × prcp_poly_k × agegroup, with the
# usual age-by-tavg polynomial and Carleton FE / clustering.
agespec_response_het_precip <- fit_response(data = mortality_data,
                                            tavg_order = 4,
                                            prcp_order = 2,
                                            prcp_interact = "prcp_tercile")
etable(agespec_response_het_precip)

# Build response curves for every (tercile, agegroup) cell.
agespec_response_het_precip_rf <- build_response(
  agespec_response_het_precip,
  x = 0:300, poly_order = 2,
  groups = tidyr::crossing(
    agegroup     = levels(mortality_data$agegroup),
    prcp_tercile = levels(mortality_data$prcp_tercile)
  ),
  key = make_coef_names("prcp_poly_",
                        interact_var = "prcp_tercile",
                        fit = agespec_response_het_precip),
  id = "Precip"
)

# tidy labels for plotting
agespec_response_het_precip_rf <- agespec_response_het_precip_rf %>%
  mutate(`Age Group` = case_when(as.character(agegroup) == "1" ~ "0 to 4",
                                 as.character(agegroup) == "2" ~ "5 to 64",
                                 as.character(agegroup) == "3" ~ "65 & above"),
         `Age Group` = factor(`Age Group`,
                              levels = c("0 to 4", "5 to 64", "65 & above")),
         `Climate Tercile` = factor(prcp_tercile,
                                    levels = c("1", "2", "3"),
                                    labels = c("Dry", "Mid", "Wet")))
