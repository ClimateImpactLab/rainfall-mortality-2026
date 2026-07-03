# Philippines Mortality Data 

These scripts prepare Philippines mortality records and population denominators for 2006–2024, attach consistent ADM identifiers, and calculate sall-cause mortality rates.

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
Rscript 03_Mortality/02_build_mortality_rates.R

Rscript 04_Descriptives/01_prepare_cause_summary.R
```

The R Markdown file can be run interactively. 

```text
04_Descriptives/02_mortality_descriptive.Rmd
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

The admin-code scripts use the PSA Philippine Standard Geographic Code
publication for the first quarter of 2026:

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

Source:
[Philippines PSGC administrative boundaries](https://github.com/altcoder/philippines-psgc-shapefiles).

## 01_Admin_Codes

The mortality metadata use four administrative coding systems:

| Label | Representative metadata sheet | Mortality years |
|---|---|---|
| `old_2006_2020` | 2006 `geocodes` | 2006–2020 |
| `new_2021_2022` | 2022 `geocodes` | 2021–2022 |
| `old_2023_2024` | 2024 `geocodes` | 2023–2024 |
| `new_2024` | 2024 `geocodes_new` | Link to current PSGC |

### 01_metadata_geocode_crosswalk.R

Builds a crosswalk between the four administrative coding systems used in the mortality metadata.
The script reads one representative metadata sheet for each system and links equivalent ADM3 units while preserving the original codes and names.
Known administrative changes are handled explicitly, and any ambiguous or unmatched units are written to a separate file for review.

```text
Inputs:
Mortality/0_Raw/PHL-PSA-VSRD-{2006,2022,2024}-PUF/*.xlsx

Outputs:
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_adm3.csv
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_exceptions.csv
```

### 02_psgc_geocodes_clean.R

Cleans the official 2026 PSGC workbook into a reference table for ADM3 units. 
Each municipality or city is linked to its ADM1 and ADM2 while preserving current and correspondence codes, names, urban/rural classification, and 2024 population.

```text
Input:
Admin_Geocodes/0_Raw/PSGC-1Q-2026-Publication-Datafile.xlsx

Output:
Admin_Geocodes/1_Clean/psgc_adm_codes.csv
```

### 03_psgc_shp_crosswalk.R

Links official PSGC administrative units to the identifiers used in the ADM1–ADM3 shapefiles. 
Matches are made using codes whenever possible, with name-based matching used only when needed. 
The output records how each match was made and keeps unresolved units separate for review.

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
Most units are matched using codes, with name-based matching used only for the remaining cases.
The final crosswalk provides consistent admin unit identifiers for all mortality years while keeping unmatched units in a separate file for review. 

```text
Inputs:
Admin_Geocodes/1_Clean/metadata_geocode_crosswalk_adm3.csv
Admin_Geocodes/2_Crosswalks/psgc_shp_crosswalk_master.csv

Outputs:
Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_adm3.csv
Admin_Geocodes/2_Crosswalks/metadata_psgc_shp_crosswalk_exceptions.csv
```

## 02_Population

The three population scripts clean four census years, align them to the same ADM3 administrative units, and interpolate annual age-sex population for 2006–2024.
Sources, methods, and intermediate outputs are documented in [`02_Population/README.md`](02_Population/README.md).

Final output:

```text
Population/2_Interpolated/PHL_population_annual_adm3.csv
```

## 03_Mortality

### 01_clean_mortality_records.R

Combines the 2006–2024 mortality files into one record-level dataset.
Year-specific differences in variable names, age coding, causes of death, and administrative codes are standardized before the files are merged.
Death dates, ages, and causes of death are cleaned into a consistent format across all years.
Place of death and residence are linked separately to consistent ADM identifiers, while preserving ADM1 and ADM2 information when no ADM3 match is available.
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

### 02_build_mortality_rates.R

Calculates residence-based all-cause mortality rates using the cleaned death records and annual ADM3 population estimates.
Mortality rates are calculated for every administrative unit in the population data, including those with no recorded deaths.
Annual rates are produced for all ages, sex, single age by sex, broad age groups (`0–4`, `5–64`, `65+`), and standard age groups (`0`, `1–4`, `5–14`, then 10-year groups through `65–74`, followed by `75–79` and `80+`). 
Monthly rates are produced for the three broad age groups using annual population estimates. 

The script also writes national summary tables and an Excel workbook with checks for record inclusion, population coverage, duplicate keys, unmatched administrative units, and deaths with zero population.


```text
Inputs:
Mortality/1_Clean/Death_Records/PHL_death_records.csv
Population/2_Interpolated/PHL_population_annual_adm3.csv

ADM3 outputs:
Mortality/1_Clean/Death_Rates/adm3_year_total.csv
Mortality/1_Clean/Death_Rates/adm3_year_sex.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_sex.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_broad.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_broad_sex.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_standard.csv
Mortality/1_Clean/Death_Rates/adm3_year_age_standard_sex.csv
Mortality/1_Clean/Death_Rates/adm3_month_age_broad.csv

National outputs:
Mortality/1_Clean/Death_Rates/national_year_total.csv
Mortality/1_Clean/Death_Rates/national_year_sex.csv
Mortality/1_Clean/Death_Rates/national_year_age_broad.csv
Mortality/1_Clean/Death_Rates/national_year_age_broad_sex.csv
Mortality/1_Clean/Death_Rates/national_year_age_standard.csv
Mortality/1_Clean/Death_Rates/national_month_age_broad.csv

Checks:
Mortality/1_Clean/Death_Rates/rate_checks.xlsx
```


## 04_Descriptives

`01_prepare_cause_summary.R` counts deaths by three-digit ICD-10 cause across 2006–2024 and writes:

```text
Mortality/1_Clean/Descriptive_Tables/phl_cause_summary.csv
```

`02_mortality_descriptive.Rmd` presents descriptive stats, cause summary, figures, and ADM3 maps.
