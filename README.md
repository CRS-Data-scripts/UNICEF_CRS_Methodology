# UNICEF Child-Focused ODA Analytical Pipeline 
Version date: 27-02-2026
Last updated: 17-06-2026

This repository contains four core R scripts implementing a reproducible analytical pipeline to identify and estimate child-focused Official Development Assistance (ODA) using OECD DAC Creditor Reporting System (CRS) data. The pipeline is designed to be deterministic: applying the same methodology to the same input data will always produce identical results.

> **Portability:** Scripts in this repository use project-relative paths and are portable across machines.

> **Input data:** The CRS Parquet file is not included in this repository. It must be downloaded separately from the [OECD Data Explorer](https://data-explorer.oecd.org/). In the Data Explorer, open **CRS: Creditor Reporting System (flows)**, choose **Download**, and select the **Parquet** version of the flows file. Place the downloaded file in `input/` as `CRS.parquet`.

> **Scope of coded pipeline:** Scripts in this repository generate compiled analytical outputs. Final analysis and charts were prepared in Excel from those compiled outputs and are shared separately.

---

## 1) Donor Script
Script: `scripts/01_donor_classification.R`

### Purpose
Builds a non-aggregated donor-level CRS output with child-focus classification flags.

### Main steps
1. Loads CRS parquet data.
2. Applies configurable early filters:
   - donor name (accent-insensitive exact match),
   - ODA flow (`IsODA`),
   - year threshold (`>= 2014`).
3. Builds `Combined_Description` from short/project/long description text.
4. Creates classification flags:
   - `c_purpose` (purpose-code based),
   - `c_channel` (channel-code based, plus channel_reported_name keyword matching),
   - `c_donor_type` (donor-code based),
   - `c_marker` (RMNCH marker based),
   - `c_keyword` (multilingual keyword regex, accent-insensitive),
   - `c_sdg` (exact-token match from `sd_gfocus` against selected SDG list).
5. Creates `c_summary = "Y"` if any classification flag is positive (`"Y"`, or for `c_keyword`, also `"Y (watsan additional)"`).
6. Optionally extracts matched keywords into `keywords_matched` column (configurable via `extract_matched_keywords` flag; pre-filters to flagged rows only for performance).
7. Optionally filters to `c_summary == "Y"`.
8. Writes final CSV output to `Output/`.

### Notes
- SDG matching uses exact token logic to avoid partial false matches (e.g., `3.1` does not match `3.10`).
- Selected purpose codes reflect an explicit targeting framework for this iteration.
- A donor-specific SDG exclusion rule is configurable via `donors_apply_sdg_exclusion_rule`. When a donor is listed, records flagged only by `c_sdg` (with no supporting purpose, channel, donor-type, marker, or keyword flag) are excluded from `c_summary`. This is currently set to `c("Australia")`. A legacy Australia-specific standalone variant in earlier local workflow files implements the same logic via a separate script.
- Optional reference file lookups can be appended to the output (donor type, channel aggregates, income group, sector aggregates, region aggregates, climate type, bilateral allocable status) via the `include_reference_files` setting. These are add-ons and do not affect the core classification.

---

## 2) Multilateral Script
Script: `scripts/03_multilateral_classification.R`

### Purpose
Builds a multilateral-focused CRS dataset and then aggregates it to donor-year outputs with child-focus metrics.

### Main steps
1. Loads CRS parquet data.
2. Applies configurable early filters:
   - donor name (optional),
   - multilateral donor-code list,
   - ODA flow,
   - year threshold (`>= 2014`).
3. Builds `Combined_Description`.
4. Creates the same classification flags as donor script (`c_purpose`, `c_channel`, `c_donor_type`, `c_marker`, `c_keyword`, `c_sdg`).
5. Creates `c_summary` from all flags (including `c_keyword = "Y (watsan additional)"`).
6. Optionally filters to `c_summary == "Y"`.
7. Aggregates to wide donor-year metrics:
   - `usd_defl_child_focus`,
   - `usd_defl_other`,
   - `usd_defl_total`,
   - `child_focus_percent`,
   - weighted `child_focus_percent_5year` (2020–2024).
8. Writes aggregated CSV output to `Output/`.

### Notes
- Uses same SDG matching and keyword methodology as donor script.
- Multilateral filter list is intentionally explicit and maintained in-script.

---

## 3) MUMS Script
Script: `scripts/04_mums_imputation.R`

### Purpose
Imports MUMS core-contribution data, joins CRS reference inputs, and imputes child-focus amounts using CRS multilateral child-focus percentages.

### Dependency note (multilateral workflow)
For the imputed multilateral approach, this script depends on:
1. the multilateral CRS output file `Output/c_crs_multi_aggregated_parquet_wide.csv` (produced by the multilateral CRS script), and
2. the bespoke bridge file `Input/Reference files/MUMS CRS Reference.csv` used to map MUMS naming to CRS donor entities.

The donor CRS script is not an input to this multilateral imputation workflow.

### Main steps
1. Imports MUMS text data (`|`-separated) via `data.table::fread`.
2. Joins first reference (`Input/Reference files/MUMS CRS Reference.csv`) on `ChannelCode` (numeric code-based join) to map MUMS channels to CRS donor fields. This avoids brittleness from text encoding variation (e.g. apostrophe variants) that can silently drop rows when joining on channel names.
3. Filters to:
   - `AidToOrThru == "Core contributions to"`,
   - `Year >= 2014`,
   - `AmountType == "Constant prices"`,
   - `FlowType == "Disbursements"`.
4. Converts missing/blank `Amount` values to `0` before aggregation so that zero-contribution rows are retained rather than dropped implicitly by `aggregate()`.
5. Aggregates MUMS `Amount` by donor/channel/year dimensions.
6. Renames columns to standardized output names.
7. Joins second reference (`Output/c_crs_multi_aggregated_parquet_wide.csv`) by year and donor code (`Year` + `CRS_multi_donor_code` to `year` + `donor_code`). Code-based join used for robustness.
8. Applies a fallback donor-code-only merge for rows where no year-specific CRS match exists (e.g. donors with gaps in annual CRS reporting). This backfills `CRS_child_focus_pct_5yr_avg_2020_2024` using the fixed 5-year average. Annual volume fields (`CRS_usd_defl_*`) remain `NA` for those rows as intended.
9. Computes `imputed_child_focus_amount = CRS_child_focus_pct_5yr_avg_2020_2024 * MUMS_amount`.
10. Exports:
    - detailed file: `Output/c_imputation_calcs.csv`,
    - summary file: `Output/c_imputation_agg.csv`.

---

## 4) Child-Focused ODA Summary Script
Script: `scripts/02_cf_summary.R`

### Purpose
Produces an all-donor × year summary of child-focused ODA across DAC and EU Institutions donors, exported as a 12-tab Excel workbook. Runs independently on the full CRS dataset.

### Main steps
1. Loads CRS parquet data and trims to required columns.
2. Filters early to DAC and EU Institutions donors using `Input/Reference files/donor_type_ref.csv`.
3. Filters to ODA flows and years from 2014 onward.
4. Applies the same classification logic as the donor script (`c_purpose`, `c_channel`, `c_donor_type`, `c_marker`, `c_keyword`, `c_sdg`).
5. Applies the Australia SDG exclusion rule and stores the adjusted summary flag as `c_summary_australia_sdg_adjusted`.
6. Applies sector classification from `Input/Reference files/purpose_ref.csv` to flag education, health, humanitarian, WATSAN, nutrition, and social protection flows.
7. Aggregates to donor × year pivot tables:
   - total ODA by donor and year,
   - child-focused ODA by donor and year,
   - child-focused ODA as a percentage of total ODA,
   - child-focused ODA as a percentage of all-donor child-focused ODA.
8. Builds equivalent sector-level breakdowns for each classified sector.
9. Exports a 12-tab Excel workbook (`Output/c_cf_summary_*.xlsx`) and a supporting pivot CSV.

### Notes
- Runs independently on the full CRS dataset — not dependent on the donor or multilateral script outputs.
- The DAC and EU Institutions filter is applied using the reference file rather than hardcoded donor codes.
- The Australia SDG exclusion rule is applied in code (hardcoded for Australia): `c_summary_australia_sdg_adjusted` is the flag used throughout all aggregations in this script.
- Uses `openxlsx` for Excel output.

---

## Code Lists and Definitions (Ordered as in Scripts)

### 1) Purpose Codes (`c_purpose`)

**Included (Yes)**

| Purpose Code | Description |
|---:|---|
| 11110 | Education policy and administrative management |
| 11120 | Education facilities and training |
| 11130 | Teacher training |
| 11182 | Educational research |
| 11220 | Primary education |
| 11231 | Basic life skills for youth |
| 11240 | Early childhood education |
| 11250 | School feeding |
| 11260 | Lower secondary education |
| 11320 | Upper Secondary Education (modified and includes data from 11322) |
| 11330 | Vocational training |
| 13020 | Reproductive health care |
| 13030 | Family planning |
| 15261 | Child soldiers (prevention and demobilisation) |

**Excluded (No)**

| Purpose Code | Description |
|---:|---|
| 14020 | Water supply and sanitation - large systems |
| 14021 | Water supply - large systems |
| 14022 | Sanitation - large systems |
| 14030 | Basic drinking water supply and basic sanitation |
| 14031 | Basic drinking water supply |
| 14032 | Basic sanitation |
| 11232 | Primary education equivalent for adults |
| 16010 | Social Protection |

Note: In this iteration, excluded purpose codes follow an explicit targeting framework rather than a welfare incidence approach.
`11232` was previously included, but its label ('Primary education equivalent for adults') reduced the need for inclusion under the current targeting approach.

### 2) Channel Codes (`c_channel`)

Channel classification uses two methods:
1. **Channel code matching**: Direct match against predefined channel codes
2. **Channel reported name matching**: Keyword regex against `channel_reported_name` field to capture additional child-focused organizations that may not have standardized codes

**Included (Yes)**

| Channel Name | Channel Code | Category |
|---|---:|---|
| Save the Children | 21505 | International NGO |
| Save the Children - donor country office | 22502 | Donor-country NGO |
| Global Campaign for Education | 21011 | International NGO |
| Forum for African Women Educationalists | 21010 | Developing country-based NGO |
| UNICEF | 41122 | Multilateral Organisation |
| Global Partnership for Education | 47501 | Multilateral Organisation |
| International Finance Facility for Education | 47147 | Multilateral Organisation |

**Excluded (No)**

- None explicitly listed in this iteration beyond non-matching channel codes.

### 3) Donor-Type Codes (`c_donor_type`)

**Included (Yes)**

| Donor Code | Donor Name |
|---:|---|
| 963 | UNICEF |

**Excluded (No)**

- None explicitly listed in this iteration beyond non-matching donor codes.

### 4) Policy Marker Mapping (`c_marker`)

**Included (Yes)**

| Marker Value | Meaning |
|---:|---|
| 1 | Significant |
| 2 | Principal |

**Excluded (No)**

- Values other than `1` or `2`.

Rule used in scripts: `c_marker = "Y"` when `rmnch` is `1` or `2`.

### 5) Keyword Methodology (`c_keyword`)

Keyword matching uses multilingual regex lists applied to a normalized `Combined_Description` field (built from `short_description`, `project_title`, and `long_description`).

**Text normalisation:**
- Punctuation is stripped and whitespace normalized before matching.
- Both keywords and text are normalized with `latin-ascii` transliteration for accent-insensitive matching.
- Regex includes separator-tolerant patterns (e.g., `[ -]?`) for hyphen/space/no-separator variants.
- Word boundaries (`\b`) are used selectively for terms at higher risk of substring false positives.

**Language gating:**

Keywords are split by language with donor-code gates to prevent cross-language false positives. Only the relevant language pattern fires for each donor.

| Language | Applied to | Donor codes |
|---|---|---|
| English | All donors (no gate) | — |
| French | French-reporting donors only | 4 (France), 2 (Belgium), 22 (Luxembourg), 301 (Canada), 5 (Germany), 918 (EU Institutions), 11 (Switzerland), 913 (African Development Bank), 914 (African Development Fund), 26 (Monaco), 988 (IFAD), 7 (Netherlands), 932 (Food and Agriculture Organisation), 1401 (WTO – International Trade Centre), 1020 (Central Emergency Response Fund), 971 (UNAIDS), 923 (UN Peacebuilding Fund), 940 (International Labour Organisation), 959 (UNDP) |
| Spanish | Spanish-reporting donors only | 50 (Spain), 910 (Central American Bank for Economic Integration), 909 (Inter-American Development Bank), 1015 (Development Bank of Latin America), 923 (UN Peacebuilding Fund), 918 (EU Institutions), 959 (UNDP) |
| Dutch | Netherlands only | 7 (Netherlands) |
| German | Germany only | 5 (Germany) |

**Excluded keywords (precision):**
- Dutch: `kind` — excluded due to high false-positive risk (common word in non-child contexts)
- German: `Kind`, `Kita` — excluded due to high false-positive risk

**Included-for-recall terms that may be reconsidered for precision:**
- English: `youth`, `youths`, `youthful`, `young person`, `youngest`
- French: `jeunesse`, `jeune`, `jeunes`, `plus jeune`
- Spanish: `juventud`, `joven`, `jovenes`, `más joven`
- Dutch: `jeugd`, `jongere`, `jongeren`, `jeugdig`, `jonge mensen`
- German: `Jugendlicher`, `Jugendliche`, `Jugend`, `jugendlich`, `die Jugend`, `junge Menschen`

**WATSAN additional rule:**
For purpose codes `14020`, `14021`, `14022`, `14030`, `14031`, `14032`, records are also marked `c_keyword = "Y (watsan additional)"` when school-equivalent terms are detected (`school`, `école/ecole`, `escuela`). This rule is based on qualitative research to improve accuracy for water/sanitation activities associated with school programmes.

**Matched keyword extraction (optional):**
When `extract_matched_keywords <- TRUE`, an additional output column `keywords_matched` is populated listing which keyword terms triggered the flag on each row. This uses `keyword_pattern_all` (all languages combined) and is pre-filtered to flagged rows only for performance.

### 6) SDG Focus Decision Table (`c_sdg`)

`c_sdg` uses exact-token matching on `sd_gfocus` with separator support (`,`, `;`, `|`, `/`) to avoid partial false matches (e.g., `3.1` does not match `3.10`).

**Donor-specific SDG exclusion rule:** In the Full donor script, a configurable list (`donors_apply_sdg_exclusion_rule`, currently set to `c("Australia")`) identifies donors for which SDG-only matches are excluded from `c_summary`. In the CF summary script, the equivalent rule is applied directly in code. SDG matches are still calculated and stored in `c_sdg`, but records flagged only by `c_sdg` are excluded from the summary classification. This adjustment was introduced because SDG-only matches materially inflated Australia's reported child-focused totals, with many such records appearing to reflect broad or indirect rather than specifically child-targeted activities.

**Included (Yes)**

| SDG | Description |
|---|---|
| 3.1 | Reduce maternal mortality |
| 3.2 | End preventable newborn/child deaths |
| 3.7 | Universal access to reproductive care |
| 4.1 | Free primary and secondary education |
| 4.2 | Quality pre-primary education access |
| 4.a | Build/upgrade inclusive and safe schools |
| 5.3 | Eliminate child/early/forced marriage and FGM |
| 8.7 | End modern slavery and child labor |
| 16.2 | End abuse/trafficking of children |

**Excluded (on basis activities could also target other age groups) (No)**

| SDG | Description |
|---|---|
| 4 | Quality Education |
| 4.3 | Equal access to affordable technical/vocational/tertiary |
| 4.4 | Increase skills for employment/success |
| 4.5 | Eliminate discrimination in education |
| 4.6 | Universal literacy and numeracy |
| 4.7 | Education for sustainable development |
| 4.b | Expand higher education scholarships |
| 4.c | Increase the supply of qualified teachers |
| 5.1 | End discrimination against women and girls |
| 5.2 | End violence/exploitation of women and girls |
| 16.9 | Provide universal legal identity (birth reg) |

### Additional Lists (Future Iterations)

- Expand donor-type mappings if additional donor codes are added.
- Optionally move detailed code dictionaries into a dedicated `METHODOLOGY.md` or `docs/` folder if this README becomes too long.

---

## Reference Files (`Input/Reference files/`)

The pipeline uses a set of reference files to map and classify CRS data. All are located in `Input/Reference files/`.

> ⚠️ **Important:** Reference files become outdated as OECD CRS taxonomies are updated, new donors/channels are added, and income group classifications change. Before running the pipeline, verify that reference files reflect the current CRS data structure and donor/country classifications. Key files to review:
> - **donor_type_ref.csv**: Check against current OECD DAC member list
> - **oecd_crs_channel_map.csv**: Verify against latest OECD channel taxonomy
> - **Recipients_regions_ref.csv** and **income_groups.csv**: Ensure country classifications match current World Bank designations
> - **purpose_ref.csv**: Confirm purpose code mappings align with current CRS structure

### 1) **donor_type_ref.csv**
Maps donor names and codes to their donor type classification (DAC, multilateral, NGO, etc.).

**Columns:**
- `donor_name`: Donor entity name
- `donor_code`: Numeric OECD DAC donor code
- `donor_type`: Classification (DAC, Multilateral, etc.)
- `donor_type_DAC_EU`: Broad grouping (DAC and EU Institutions, or other)

**Used by:** CF summary script (to filter to DAC and EU Institutions donors)

---

### 2) **purpose_ref.csv**
Comprehensive mapping of OECD CRS purpose codes to sector classifications and multiple aggregation hierarchies.

**Columns:**
- `purpose_code`: OECD CRS purpose code
- `purpose_name`: Human-readable description
- `sector_code`: Sector grouping code
- `sector_name`: Sector name (e.g., "I.1.a. Education, Level Unspecified")
- `Aggregate sectors 1–4`: Multiple levels of sector aggregation
- `IDRC`, `IDRC WASH SP`: IDRC-specific classifications
- `Non-transfer`, `Non-transfer WASH SP`: Non-transfer flags for filtering

**Used by:** CF summary script (to classify outputs into education, health, humanitarian, WATSAN, nutrition, social protection sectors)

---

### 3) **MUMS CRS Reference.csv**
Bridge file mapping MUMS channel codes and names to CRS donor entities. Avoids brittleness from text encoding variation (e.g., apostrophe variants).

**Columns:**
- `ChannelNameE`: MUMS channel name (English)
- `ChannelCode`: Numeric MUMS channel code
- `CRS Donor name`: Mapped CRS donor name
- `CRS Donor code`: Mapped OECD DAC donor code
- `de_donorcode`: Alternative donor code identifier

**Used by:** MUMS script (Step 2 join: maps MUMS data to CRS donor fields for imputation workflow)

---

### 4) **oecd_crs_channel_map.csv**
Detailed OECD CRS channel taxonomy with parent categories, years added, and coefficients for core contributions.

**Columns:**
- `channel_parent_category_code`: Parent channel category
- `channel_id_code`: Unique channel identifier
- `year_added`: Year code was introduced
- `acronym_eng`: English acronym
- `oecd_channel_name`: Official OECD channel name
- `oecd_channel_parent_name`: Parent category name
- `oecd_aggregated_channel`: Aggregated grouping
- `coefficient_for_core_contributions`: Numeric weighting for contributions
- Additional columns for MCD delivery type and references

**Used by:** Scripts use this for channel reference data and aggregation logic

---

### 5) **Recipients_regions_ref.csv**
Maps recipient country codes to geographic regions and region aggregation levels.

**Columns:**
- `recipient_name`: Recipient country name
- `recipient_code`: Numeric recipient code
- `de_recipientcode`: Alternative recipient code
- `region_name`: Region classification
- `region_code`: Numeric region code
- `Region aggregated 1–2`: Multiple aggregation levels

**Used by:** Optional reference file append (if `include_reference_files = TRUE` in donor script)

---

### 6) **income_groups.csv**
World Bank income group classification for recipient countries.

**Columns:**
- `Economy`: Country name
- `Code`: ISO 3-letter country code
- `Region`: Geographic region (World Bank classification)
- `Income group`: Classification (Low income, Lower middle, Upper middle, High income)
- `Lending category`: World Bank lending category (IDA, IBRD, etc.)

**Used by:** Optional reference file append (if `include_reference_files = TRUE` in donor script)

---

### 7) **aid_types_ref.csv**
Classification of CRS aid type codes (bilateral, unallocable, etc.).

**Used by:** Optional reference file append; structure mirrors CRS aid type taxonomy

---

### 8) **SDGs.xlsx** (Excel)
Supplementary reference for SDG code definitions and mappings. Corresponds to the SDG include/exclude lists in Section 6 (SDG Focus Decision Table).

**Used by:** Reference and documentation only; SDG logic is hardcoded in scripts

---

### 9) **MUMS CRS Reference file.xlsx** (Excel)
Alternative format version of MUMS CRS Reference (also available as `.csv`). Used for manual review and Excel-based workflows.

---

### 10) **GAVI Contributions file** (Excel)
GAVI Vaccine Alliance contribution and proceeds data (as of December 2024). Available for optional manual cross-reference.

---

### Reference File Usage Summary

| Script | Primary Files | Optional Files |
|---|---|---|
| **Donor Script** | None (hardcoded classification logic) | `donor_type_ref.csv`, `purpose_ref.csv`, `Recipients_regions_ref.csv`, `income_groups.csv`, `aid_types_ref.csv` |
| **Multilateral Script** | None (hardcoded classification logic) | Same as donor script |
| **CF Summary Script** | `donor_type_ref.csv`, `purpose_ref.csv` | Other reference files |
| **MUMS Script** | `MUMS CRS Reference.csv` (join step 1), `Output/c_crs_multi_aggregated_parquet_wide.csv` (join step 2) | None |

---

## Reproducibility and Version Control

This analytical pipeline is designed to meet the standards of a reproducible analytical workflow consistent with the UN Fundamental Principles of Official Statistics (transparency, professional standards, and methodological clarity).

**Current status:**
- ✅ Fully scripted, deterministic pipeline (same inputs → same outputs)
- ✅ Methodological decisions documented inline (purpose code exclusions, keyword precision/recall notes, WATSAN rule rationale)
- ✅ Keyword dictionaries encoded in code with language-gating logic
- ✅ Modular classification structure (purpose codes, channels, markers, keywords, SDGs as separate flags)
- ✅ File paths use relative paths — portable across machines
- ✅ Git version control initialised
- ✅ Repository published at [github.com/CRS-Data-scripts/UNICEF_CRS_Methodology](https://github.com/CRS-Data-scripts/UNICEF_CRS_Methodology)

**Execution order for multilateral imputation outputs:**
1. Run `scripts/03_multilateral_classification.R` to produce `Output/c_crs_multi_aggregated_parquet_wide.csv`.
2. Run `scripts/04_mums_imputation.R`, which uses that output plus `Input/Reference files/MUMS CRS Reference.csv` as the MUMS–CRS naming bridge.

The donor script (`scripts/01_donor_classification.R`) and CF summary script (`scripts/02_cf_summary.R`) are each standalone workflows and are not required for the imputed multilateral output files.

**Planned repository structure (illustrative):**
```
├── README.md
├── scripts/
│   ├── 01_donor_classification.R
│   ├── 02_cf_summary.R
│   ├── 03_multilateral_classification.R
│   └── 04_mums_imputation.R
├── input/
│   └── (CRS Parquet file — downloaded separately from OECD DAC)
├── output/
│   └── (generated CSV outputs)
└── docs/
   └── METHODOLOGY.md
```
