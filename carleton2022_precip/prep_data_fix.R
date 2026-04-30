#========================================================================================#
#' Prepare data for regressions following 
#' https://github.com/ClimateImpactLab/carleton_mortality_2022/blob/main/1_estimation/1_utils/prep_data.do
#'
#' Created By: Nishka Sharma
#' Date Created: Apr 24 2025
#'
#' Produces:
#'   - cleaned and regression ready global_mortality_panel
#=========================================================================================#

# check data
# nrow(mortality_data)
# head(mortality_data)
# colnames(mortality_data)

# create adm0 LR averages (one year one vote given imbalanced sample)
avg_inc <- mortality_data %>%
    group_by(iso, year) %>%
    slice(1) %>%
    ungroup() %>%
    group_by(iso) %>%
    summarise(loggdppc_adm0_avg = mean(loggdppc_adm0, na.rm = TRUE))

# merge in sample average incomes. remove years after 2010 and agegroup = 0
mortality_data <- mortality_data %>%
    # left_join(avg_inc, by = "iso") %>% # this command keep crashing jupyter
    filter(year <= 2010, agegroup != 0)

# create winsorized deathrate with-in country-agegroup
mortality_data <- mortality_data %>%
    group_by(iso, agegroup) %>%
  #  mutate(deathrate_w99 = pmin(deathrate, quantile(deathrate, 0.99, na.rm = TRUE))) %>%
    mutate(deathrate_w99 = pmin(deathrate, quantile(deathrate, 0.99, na.rm = TRUE, type = 2))) %>%
    ungroup()

# set up sample 
# mortality_data <- mortality_data %>%
#     mutate(sample = 0,
#            sample = case_when(
#                agegroup != 0 & year <= 2010 ~ 1,
#                is.na(deathrate_w99) ~ 0,
#                is.na(tavg_poly_1_GMFD) ~ 0,
#                is.na(prcp_poly_1_GMFD) ~ 0,
#                is.na(loggdppc_adm1_avg) ~ 0,
#                is.na(lr_tavg_GMFD_adm1_avg) ~ 0
#            )) %>%
#     filter(sample == 1)
mortality_data <- mortality_data %>%
  filter(!is.na(deathrate_w99),
         !is.na(tavg_poly_1_GMFD),
         !is.na(prcp_poly_1_GMFD),
         !is.na(loggdppc_adm1_avg),
         !is.na(lr_tavg_GMFD_adm1_avg))
# clean up ids
mortality_data <- mortality_data %>%
    mutate(adm2_id = if_else(iso == "JPN", adm1_id, adm2_id)) %>%
    group_by(iso) %>%
    mutate(adm0_code = cur_group_id()) %>%
    group_by(iso, adm1_id) %>%
    mutate(adm1_code = cur_group_id()) %>%
    group_by(iso, adm1_id, adm2_id) %>%
    mutate(adm2_code = cur_group_id()) %>%
    group_by(iso, agegroup) %>%
    mutate(adm0_agegrp_code = cur_group_id()) %>%
    group_by(iso, adm1_id, agegroup) |>
    mutate(adm1_agegrp_code = cur_group_id()) %>%
    ungroup()

# assign EU countries same adm0_code
mortality_data <- mortality_data %>%
    mutate(adm0_code2 = 41,
           adm0_code2 = case_when(
               adm0_code == 4 ~ 4, # BRA
               adm0_code == 6 ~ 6, # CHL
               adm0_code == 7 ~ 7, # CHN
               adm0_code == 15 ~ 15, # FRA
               adm0_code == 23 ~ 23, # JPN
               adm0_code == 27 ~ 27, # MEX
               adm0_code == 40 ~ 40 # USA
           ),
           iso2 = iso,
           iso2 = ifelse(adm0_code2==41, "EUR", iso),
           # Assign separate FEs to each time series segment for CHN DSPs that appear in both.
           CHN_ts = 1,
           CHN_ts = ifelse(year >= 2004 & iso=="CHN", 2, CHN_ts))


