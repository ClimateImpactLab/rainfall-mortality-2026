# Philippines Population Data

These scripts create annual municipality-level population estimates for the Philippines covering 2006–2024.

The estimates combine information from the 2007, 2010, 2015, and 2020 population censuses, express every year using the same ADM3 administrative units, and interpolate annual population by age and sex.

The final dataset contains population at the following level:

```text
year × current ADM3 × age × sex
```

The output:

- covers 2006–2024
- includes the 1,642 municipalities and cities represented in the 2020 mortality data
- retains separate male and female population counts 
- uses single-year ages from 0–79 plus a single 80+ category

The annual population estimates are later merged with the mortality data to calculate mortality rates. 


## Data locations

Data root directory: 

```text
/project/cil/battuta_shares/gcp/estimation/mortality/release_2020/data/0_data_cleaning/1_raw/Countries/New_Countries/PHL
```

| Data | Location |
| --- | --- |
| Raw census data | `Population/0_Raw/` |
| Clean census-year data | `Population/1_Clean/` |
| Annual population estimates | `Population/2_Interpolated/` |
| Administrative codes and crosswalks | `Admin_Geocodes/` |

## Scripts

Scripts location: 

```text
rainfall-mortality-2026/1_data/mortality_data/1_cleaning/PHL/02_Population
```

Run all four scripts in `../01_Admin_Codes` first. Then run these scripts from
the `02_Population` directory:

```bash
Rscript 01_clean_population_census_years.R
Rscript 02_align_adm3_boundaries.R
Rscript 03_interpolate_population.R
```

3 steps:

1. Clean and harmonize the available census years
2. Align all census years to the current ADM3 administrative units
3. Interpolate annual population estimates for 2006–2024


## 1. Clean and harmonize census years

**Script**

```text
01_clean_population_census_years.R
```

This script reads the four available census sources, standardizes them into a common format, and produces municipality-level population counts by age and sex for each census year.

**census files source:**

| Year | Source | Local input |
| --- | --- | --- |
| 2007 | [PSADA 2007 Population Census (POPCEN)](https://psada.psa.gov.ph/catalog/16), person-level public-use files | `Population/0_Raw/PHL-PSA-POPCEN-2007-PUF/` |
| 2010 | [PSADA 2010 Census of Population and Housing (CPH)](https://psada.psa.gov.ph/catalog/13), Form 2 non-sample person-level files | `Population/0_Raw/PHL-PSA-CPH-2010-PUF/Form 2 - Non Sample/` |
| 2015 | [HDX/PSA barangay-level age-sex table](https://data.humdata.org/dataset/philippines-2015-census-population-admin4-single-age) | `Population/0_Raw/180816_philippines-population-barangay-admin-4_2015-single-age.csv` |
| 2020 | [HDX/PSA barangay-level age-sex table]( https://data.humdata.org/dataset/philippines-2015-census-population-admin4-single-age) | `Population/0_Raw/2020-census-total-popn_single-age_malefemale_admin4.xlsx` |

The 2007 and 2010 census microdata are aggregated from person records, while the 2015 and 2020 barangay tables are reshaped and aggregated from ADM4 to ADM3.

Administrative codes are linked using:

```text
Admin_Geocodes/1_Clean/psgc_adm_codes.csv
Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv
```

**Ouputs:**

```text
Population/1_Clean/census_pop_pre_alignment.csv
Population/1_Clean/census_pre_alignment_checks.xlsx
```


## 2. Align census years to the current ADM3 administrative units

**Script**

```text
02_align_adm3_boundaries.R
```

Express every census year using the same set of 1,642 municipalities and cities represented in the 2020 mortality data.

Older censuses contain fewer municipalities because some current administrative units had not yet been created. 
This script reallocates historical population where municipality boundaries changed.

### Method

Population is redistributed using shares from the earliest census in which the current municipalities exist.

Specifically,

- 2020 shares are used for the BARMM Special Geographic Area municipalities
- 2010 shares are used for municipality changes affecting only the 2007 census
- Pikit Cluster III is allocated using both Pikit and Aleosan because its barangays originated from both municipalities

These adjustments preserve population totals within each census year, age, and sex. 

**Outputs**
```text
Population/1_Clean/census_pop_final.csv
Population/1_Clean/census_final_checks.xlsx
```


## 3. Interpolate annual population

**Script**

```text
03_interpolate_population.R
```

Convert the four cleaned census years into annual municipality-level population estimates covering 2006–2024.
Municipality totals and age-sex composition are interpolated separately because official 2024 municipality totals are available, but no corresponding age-sex breakdown has been published.

Municipality totals are linearly interpolated between:
- 2007
- 2010
- 2015
- 2020
- 2024

The 2007–2010 trend is extended backward one year to estimate 2006.

Age-sex shares are handled independently:

- shares are linearly interpolated between census years
- the 2007 age-sex distribution is used for 2006
- the 2020 age-sex distribution is used for 2021–2024

Annual age-sex population is obtained by multiplying the interpolated municipality total by the corresponding age-sex share.

Holding the observed 2020 age-sex distribution after 2020 avoids extrapolating small age-sex shares beyond the available census years, which can produce negative values.

**Outputs:**

```text
Population/2_Interpolated/PHL_population_annual_adm3.csv
Population/2_Interpolated/interpolation_checks.xlsx
```



**Note**

Age-sex shares are only interpolated between observed census years. For 2006, the 2007 age-sex distribution is used, and for 2021–2024, the 2020 age-sex distribution is used. This avoids extrapolating age-sex trends beyond the available census data while preserving the official 2024 municipality/city population totals.

Previous versions of this script extrapolated age-sex shares outside the observed census period. In some ADM3-age-sex cells, this produced negative projected shares that were truncated to zero, creating artificial zero-population counts. Holding the nearest observed age-sex distribution outside the census period avoids this issue.

A more comprehensive demographic approach would use a [cohort-component projection method](https://www.census.gov/programs-surveys/popproj/about.html), which projects age-sex populations using fertility, mortality, and migration.
However, this requires demographic inputs that are not currently available at the ADM3 level.
