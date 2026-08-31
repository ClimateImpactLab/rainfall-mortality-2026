# Philippines Mortality Data



These scripts prepare Philippines mortality records and population denominators for 2006–2024, link the mortality records to consistent ADM identifiers, and calculate all-cause mortality rates.

## Directory structure

Folders:

```text
PHL/

├── README.md
├── paths.R
├── 01_Admin_Codes/
├── 02_Population/
├── 03_Mortality/
└── 04_Descriptives/
```

Scripts:

```bash
Rscript 01_Admin_Codes/01_metadata_geocode_crosswalk.R
Rscript 01_Admin_Codes/02_psgc_geocodes_clean.R
Rscript 01_Admin_Codes/03_psgc_shp_crosswalk.R
Rscript 01_Admin_Codes/04_metadata_psgc_shp_crosswalk.R

Rscript 02_Population/01_clean_population_census_years.R
Rscript 02_Population/02_align_adm3_boundaries.R
Rscript 02_Population/03_interpolate_population.R

Rscript 03_Mortality/01_clean_mortality_records.R
Rscript 03_Mortality/03_align_mortality_boundaries.R
Rscript 03_Mortality/02_build_mortality_rates.R
Rscript 03_Mortality/04_build_final_panel.R

Rscript 04_Descriptives/01_prepare_cause_summary.R
Rscript 04_Descriptives/02_check_original_vs_aligned_low_rates.R
Rscript 04_Descriptives/03_check_barmm_low_rates.R
```

To rerun all PHL mortality scripts on a compute node:

```bash
sbatch run_phl_mortality.sbatch
```

The R Markdown descriptive file can be run interactively:

```text
04_Descriptives/04_mortality_descriptive_new.Rmd
```

## Data sources

### Mortality records

The annual death records are Philippine Statistics Authority (PSA) Vital Statistics Report on Deaths public-use files from the [PSA Data Archive](https://psada.psa.gov.ph/catalog/VSR/about).

```text
Mortality/0_Raw/PHL-PSA-VSRD-2006-PUF/
...
Mortality/0_Raw/PHL-PSA-VSRD-2024-PUF/
```

Each directory contains a death-record workbook and its metadata workbook.

### PSGC reference

The admin-code scripts use the PSA Philippine Standard Geographic Code publication for the first quarter of 2026:

```text
Admin_Geocodes/0_Raw/PSGC-1Q-2026-Publication-Datafile.xlsx
```

Source: [PSA PSGC publication page](https://psa.gov.ph/classification/psgc/summary).

### Administrative boundaries

The ADM1–ADM3 shapefiles are:

```text
Shapefiles/Post2023/PH_Adm1_Regions.shp
Shapefiles/Post2023/PH_Adm2_ProvDists.shp
Shapefiles/Post2023/PH_Adm3_MuniCities.shp
```

Source: [Philippines PSGC administrative boundaries](https://github.com/altcoder/philippines-psgc-shapefiles).

## 01_Admin_Codes

The mortality metadata use four administrative coding systems:

| Label           | Representative metadata sheet | Mortality years      |
| --------------- | ----------------------------- | -------------------- |
| `old_2006_2020` | 2006 `geocodes`               | 2006–2020            |
| `new_2021_2022` | 2022 `geocodes`               | 2021–2022            |
| `old_2023_2024` | 2024 `geocodes`               | 2023–2024            |
| `new_2024`      | 2024 `geocodes_new`           | Link to current PSGC |

### 01_metadata_geocode_crosswalk.R

Builds a crosswalk between the four administrative coding systems used in the mortality metadata.

The script reads one representative metadata sheet for each system and links equivalent ADM3 units while keeping the original codes and names. Known administrative changes are handled explicitly. Ambiguous or unmatched units are written to a separate file for review.

```text
Inputs:
Mortality/0_Raw/PHL-PSA-VSRD-{2006,2022,2024}-PUF/*.xlsx

Outputs:
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_adm3.csv
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_exceptions.csv
```

### 02_psgc_geocodes_clean.R

Cleans the official 2026 PSGC workbook into a reference table for ADM3 units.

Each municipality or city is linked to its ADM1 and ADM2. The cleaned file keeps current and correspondence codes, names, urban/rural classification, and 2024 population.

```text
Input:
Admin_Geocodes/0_Raw/PSGC-1Q-2026-Publication-Datafile.xlsx

Output:
Admin_Geocodes/1_Clean/psgc_adm_codes.csv
```

### 03_psgc_shp_crosswalk.R

Links official PSGC administrative units to the identifiers used in the ADM1–ADM3 shapefiles.

Codes are used whenever possible, with name matching used only when needed. The output records how each match was made and keeps unresolved units separate for review.

```text
Inputs:
Admin_Geocodes/1_Clean/psgc_adm_codes.csv
Shapefiles/Post2023/PH_Adm1_Regions.shp
Shapefiles/Post2023/PH_Adm2_ProvDists.shp
Shapefiles/Post2023/PH_Adm3_MuniCities.shp

Output:
Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv
```

### 04_metadata_psgc_shp_crosswalk.R

Connects the mortality metadata codes to the official PSGC and shapefile identifiers.

Most units are matched using codes, with name matching used for the remaining cases. The final crosswalk gives the mortality data consistent admin identifiers across years. Unmatched units are written separately for review.

```text
Inputs:
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_adm3.csv
Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv

Outputs:
Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_adm3.csv
Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_exceptions.csv
```

## 02_Population

The three population scripts clean four census years, align them to the same ADM3 units, and interpolate annual age-sex population for 2006–2024.

Sources, methods, and intermediate outputs are documented in [`02_Population/README.md`](02_Population/README.md).

Final output:

```text
Population/2_Interpolated/PHL_population_annual_adm3.csv
```

## 03_Mortality

### 01_clean_mortality_records.R

Combines the 2006–2024 mortality files into one record-level dataset.

Year-specific differences in variable names, age coding, causes of death, and administrative codes are standardized before the files are combined. Death dates, ages, and causes of death are cleaned into a consistent format across years.

Place of death and residence are linked separately to consistent ADM identifiers, while keeping ADM1 and ADM2 information when no ADM3 match is available.

The script also checks that the joins do not duplicate death records and reports unmatched administrative codes.

```text
Inputs:
Mortality/0_Raw/PHL-PSA-VSRD-YYYY-PUF/*.xlsx
Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_adm3.csv

Outputs:
Mortality/1_Clean/Death_Records/PHL_death_records.csv
Mortality/1_Clean/Death_Records/PHL_death_records.dta
Mortality/1_Clean/Death_Records/PHL_unmatched_geocodes.csv
```

### 03_align_mortality_boundaries.R

Aligns resident ADM3 identifiers in the cleaned mortality records to the fixed ADM3 geography used for the population denominators and final panel.

This step handles administrative changes that would otherwise leave the mortality records and population data on different ADM3 boundaries. The aligned file is then used to calculate the mortality rates.

```text
Input:
Mortality/1_Clean/Death_Records/PHL_death_records.csv

Output:
Mortality/1_Clean/Death_Records/PHL_death_records_adm3_aligned.csv
```

### 02_build_mortality_rates.R

Calculates residence-based all-cause mortality rates using the ADM3-aligned death records and annual ADM3 population estimates.

Mortality rates are calculated for every administrative unit in the population data, including units with no recorded deaths.

Annual rates are produced for all ages, sex, single age by sex, broad age groups (`0–4`, `5–64`, `65+`), and standard age groups (`0`, `1–4`, `5–14`, then 10-year groups through `65–74`, followed by `75–79` and `80+`).

Monthly rates are produced for the three broad age groups using annual population estimates.

The script also writes national summary tables and an Excel workbook with output checks. The final panel uses the `_no_barmm` annual all-age and broad-age ADM3 files.

```text
Inputs:
Mortality/1_Clean/Death_Records/PHL_death_records_adm3_aligned.csv
Population/2_Interpolated/PHL_population_annual_adm3.csv

Main ADM3 outputs used later:
Mortality/1_Clean/Death_Rates/adm3_year_total.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_broad.csv
Mortality/1_Clean/Death_Rates/adm3_year_total_no_barmm.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_broad_no_barmm.csv

Other sex, age-sex, monthly, and national summaries are written to:
Mortality/1_Clean/Death_Rates/

Checks:
Mortality/1_Clean/Death_Rates/rate_checks.xlsx
```

### 04_build_final_panel.R

Builds the ADM3 mortality and population panel used in the global panel.

The file uses the BARMM-excluded all-age and broad-age rate files and maps age groups to the global codes:

```text
0 = all ages
1 = ages 0-4
2 = ages 5-64
3 = ages 65+
```

The final geography is ADM3 city/municipality. `admin_id` is `shp_adm3_code`, which matches the ADM3 shapefile field `adm3_psgc` used by the climate aggregation.

Most shapefile IDs match the current official PSGC code. Negros Island Region units keep the shapefile-compatible codes because the climate and GHSL extractions use the existing ADM3 shapefile IDs.

```text
Inputs:
Mortality/1_Clean/Death_Rates/adm3_year_total_no_barmm.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_broad_no_barmm.csv

Outputs:
data/0_data_cleaning/3_final/PHL/PHL_mortality_population_panel_adm3_year_agegroup_no_barmm.csv
data/0_data_cleaning/3_final/PHL/PHL_mortality_population_panel_adm3_year_agegroup_no_barmm_audit.xlsx
data/0_data_cleaning/3_final/PHL/README.md
```

### BARMM exclusion decision

BARMM is excluded from ADM3-level mortality-rate analysis and panel integration.

The exclusion is based on several checks:

* BARMM drives unusual one-year and five-year ADM3 population changes.
* BARMM contains 277 of 279 high-population zero-death ADM3-years.
* BARMM contains 1,872 of 2,154 ADM3-years with death rates below 100 per 100,000.
* BARMM has many province-years with implausibly low resident death totals relative to national expected deaths.
* The remaining high-population zero-death cases were already present in the original death records and were not created by the mortality boundary reallocation.

Dropping BARMM removes 119 ADM3 units and 2,261 ADM3-year observations, leaving 1,523 ADM3 units and 28,937 ADM3-year observations for 2006–2024.

Detailed checks and supporting workbooks are in:

```text
Country_Descriptives/PHL/phl_low_rate_investigation/README.md
Country_Descriptives/PHL/phl_low_rate_investigation/phl_original_vs_aligned_low_rates.xlsx
Country_Descriptives/PHL/phl_low_rate_investigation/phl_barmm_low_rate_followup_checks.xlsx
```

## 04_Descriptives

`01_prepare_cause_summary.R` counts deaths by three-digit ICD-10 cause across 2006–2024 and writes:

```text
Mortality/1_Clean/Descriptive_Tables/phl_cause_summary.csv
Mortality/1_Clean/Descriptive_Tables/phl_cause_summary_no_barmm.csv
```

`02_check_original_vs_aligned_low_rates.R` checks whether high-population zero-death ADM3-years were already present before mortality records were aligned to the fixed ADM3 geography.

`03_check_barmm_low_rates.R` follows up on low resident mortality rates in BARMM using national expected deaths, nearby-year rates, repeated zero-death ADM3s, and place-of-death counts.

`04_mortality_descriptive_new.Rmd` presents mortality descriptive statistics, cause-of-death summaries, population checks, figures, and ADM3 maps.
