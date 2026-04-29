#========================================================================================#
#' Precip responses by country and age group  
#'
#' Created By: Nishka Sharma
#' Date Created: Apr 22 2025
#'
#' Produces:
#'   - a grid plot of precip responses for all countries in the Carleton 2022
#'     paper to establish a baseline for the rainfall-mortality project
#'
#' How To Run:
#'   - Items under "change this section to customise plots" control what is plotted 
#=========================================================================================#

#==============================================================================#
packages = c("tidyr", "ggplot2", "dplyr", "magrittr", "readr", "glue", "scales", 
             "parallel", "RColorBrewer", "MetBrewer")

message(" ---- loading packages ---- ")
invisible(lapply(packages, function(pkg) {
  suppressPackageStartupMessages(library(pkg, character.only = TRUE))
}))

rm(packages)

#==============================================================================#
# get user and source paths
USER = Sys.getenv("USER")
# source(glue("/project/cil/home_dirs/{USER}/repos/labor-code-release-2020/0_subroutines/paths.R"))
# 
# # source labor utils/functions.
# Rfiles = Sys.glob(glue("{DIR_REPO_LABOR}", "/4_post_projection/0_utils/*.R"))
# Rfiles = Rfiles[!mapply(x=Rfiles, grepl, MoreArgs=list(pattern='load_utils'))]
# null = lapply(Rfiles, source)

#==================change this section to customise plots======================#
`%notin%` <- Negate(`%in%`)
# input path to single/median/mc
input_path = "/project/cil/home_dirs/nishkasharma/misc/rainfall_mortality"

#==============================================================================#
rf <- read_csv(glue(input_path, "/output/data/precip_response_by_iso.csv"))

rf <- rf %>%
  select(adm0, iso, prcp_value, starts_with("yhat"), starts_with("se"), 
         starts_with("lowerci"), starts_with("upperci"))

# Cyprus, Estonia, Iceland, Lithuania, Luxembourg, Latvia, Macedonia, Malta,
# and Montenegro have empty coefficients
empty_resp <- c("CYP", "EST", "ISL", "LTU", "LUX", "LVA", "MKD", "MLT", "MNE")

rf_plot <- rf %>%
  pivot_longer(cols = c(starts_with("yhat"), starts_with("se"), 
                        starts_with("lowerci"), starts_with("upperci")),
               names_to      = c(".value", "agegroup"),
               names_pattern = "^(yhat|se|lowerci|upperci)_(.*)") %>%
  mutate(agegroup = case_when(agegroup == "0_4" ~ "0 to 4",
                              agegroup == "5_64" ~ "5 to 64",
                              agegroup == "65_above" ~ "65 & above"),
         agegroup = factor(agegroup, levels = c("0 to 4", "5 to 64", "65 & above"))) %>%
  filter(iso %notin% empty_resp )

color_palette <- met.brewer("Hokusai3", n = 3)

p = rf_plot %>%
  ggplot() +
  facet_wrap(vars(adm0), nrow = 4, ncol = 8, scales = "free_y") +
  geom_hline(yintercept = 0, linewidth = 1, color="black") +
  geom_line(aes(x = prcp_value, y = yhat, color = agegroup), linewidth = 1) +
  # geom_ribbon(aes(x = prcp_value, ymin = lowerci, ymax = upperci, 
  #                 fill = agegroup), alpha = 0.3) +
  scale_color_manual(values = color_palette) +
  # scale_fill_manual(values = color_palette) +
  labs(x = "Precipitation (mm)",
       y = "Mortality rate (per 100,000)",
       color = "Age group (years)") +
  theme_classic() +
  theme(legend.key.spacing.y = unit(0.3, "cm") ,
        legend.key.width = unit(1.5, "cm"),
        axis.line = element_line(color = "black", linewidth = 1),
        axis.text = element_text(size = 10),
        axis.title = element_text(size = 14),
        plot.title = element_text(size = 16, face = "bold"),
        strip.text = element_text(size = 12)) # +
    # guides(fill = "none")
ggsave(glue(input_path, "/output/figures/precip_response/all_ages.png"), width = 16, height = 10)

p_age1 = rf_plot %>%
  filter(agegroup == "0 to 4") %>%
  ggplot() +
  facet_wrap(vars(adm0), nrow = 4, ncol = 8, scales = "free_y") +
  geom_hline(yintercept = 0, linewidth = 1, color="black") +
  geom_line(aes(x = prcp_value, y = yhat), color = "#95c46e", linewidth = 1) +
  geom_ribbon(aes(x = prcp_value, ymin = lowerci, ymax = upperci),
              fill = "#95c46e", alpha = 0.3) +
  # scale_color_manual(values = color_palette) +
  # scale_fill_manual(values = color_palette) +
  labs(x = "Precipitation (mm)",
       y = "Mortality rate (per 100,000)",
       title = "Precip response for agegroup = 0 to 4") +
  theme_classic() +
  theme(legend.key.spacing.y = unit(0.3, "cm") ,
        legend.key.width = unit(1.5, "cm"),
        axis.line = element_line(color = "black", linewidth = 1),
        axis.text = element_text(size = 10),
        axis.title = element_text(size = 14),
        plot.title = element_text(size = 16, face = "bold"),
        strip.text = element_text(size = 12))
ggsave(glue(input_path, "/output/figures/precip_response/0to4.png"), width = 15, height = 10)

p_age2 = rf_plot %>%
  filter(agegroup == "5 to 64") %>%
  ggplot() +
  facet_wrap(vars(adm0), nrow = 4, ncol = 8, scales = "free_y") +
  geom_hline(yintercept = 0, linewidth = 1, color="black") +
  geom_line(aes(x = prcp_value, y = yhat), color = "#5a97c1", linewidth = 1) +
  geom_ribbon(aes(x = prcp_value, ymin = lowerci, ymax = upperci),
              fill = "#5a97c1", alpha = 0.3) +
  # scale_color_manual(values = color_palette) +
  # scale_fill_manual(values = color_palette) +
  labs(x = "Precipitation (mm)",
       y = "Mortality rate (per 100,000)",
       title = "Precip response for agegroup = 5 to 64") +
  theme_classic() +
  theme(legend.key.spacing.y = unit(0.3, "cm") ,
        legend.key.width = unit(1.5, "cm"),
        axis.line = element_line(color = "black", linewidth = 1),
        axis.text = element_text(size = 10),
        axis.title = element_text(size = 14),
        plot.title = element_text(size = 16, face = "bold"),
        strip.text = element_text(size = 12))
ggsave(glue(input_path, "/output/figures/precip_response/5to64.png"), width = 15, height = 10)

p_age3 = rf_plot %>%
  filter(agegroup == "65 & above") %>%
  ggplot() +
  facet_wrap(vars(adm0), nrow = 4, ncol = 8, scales = "free_y") +
  geom_hline(yintercept = 0, linewidth = 1, color="black") +
  geom_line(aes(x = prcp_value, y = yhat), color = "#295384", linewidth = 1) +
  geom_ribbon(aes(x = prcp_value, ymin = lowerci, ymax = upperci),
              fill = "#295384", alpha = 0.3) +
  # scale_color_manual(values = color_palette) +
  # scale_fill_manual(values = color_palette) +
  labs(x = "Precipitation (mm)",
       y = "Mortality rate (per 100,000)",
       title = "Precip response for agegroup = 65 & above") +
  theme_classic() +
  theme(legend.key.spacing.y = unit(0.3, "cm") ,
        legend.key.width = unit(1.5, "cm"),
        axis.line = element_line(color = "black", linewidth = 1),
        axis.text = element_text(size = 10),
        axis.title = element_text(size = 14),
        plot.title = element_text(size = 16, face = "bold"),
        strip.text = element_text(size = 12))
ggsave(glue(input_path, "/output/figures/precip_response/65above.png"), width = 15, height = 10)


