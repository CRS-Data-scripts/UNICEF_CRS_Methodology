# Methodology

## Purpose

This document describes the analytical methodology used to identify and estimate child-focused Official Development Assistance (ODA) in the UNICEF analytical pipeline.

The methodology is implemented in R and applied consistently across the donor CRS script, the child-focused ODA summary script, the multilateral CRS script, and the MUMS imputation script.

---

## Analytical Objective

The objective is to identify activities that are plausibly child-focused using a rules-based framework applied to OECD DAC Creditor Reporting System (CRS) records, and then to use those results to estimate imputed multilateral child-focused ODA.

The methodology uses five identification dimensions:

1. purpose codes
2. channels of delivery
3. policy markers
4. SDG focus
5. keyword search

A record is classified as child-focused at summary level when one or more of these dimensions is triggered.

---

## Data Sources

### 1. OECD DAC CRS flows data
Used for donor-level and multilateral classification.

Primary input fields used in the current scripts include:
- `donor_code`
- `donor_name`
- `purpose_code`
- `channel_code`
- `channel_reported_name`
- `rmnch`
- `sd_gfocus`
- `short_description`
- `project_title`
- `long_description`
- financial value fields used in multilateral aggregation

### 2. MUMS core contribution data
Used to estimate imputed multilateral child-focused ODA by combining core contribution amounts with CRS-derived multilateral child-focus shares.

### 3. Reference files
Used in the MUMS script to map MUMS channel names to CRS donor entities.

Optional reference file lookups are also available in the donor script and CF summary script to append supplementary fields (donor type, channel aggregates, income group, sector aggregates, region aggregates, climate type, and bilateral allocable status). These are configurable add-ons and are not part of the core classification methodology.

---

## Processing Overview

### Donor CRS pipeline
The donor script:
- loads CRS Parquet data
- optionally filters by donor name
- filters to ODA flows
- filters to reporting years from 2014 onward unless changed in settings
- creates classification flags
- creates a summary flag `c_summary`
- optionally extracts matched keywords
- exports a non-aggregated CSV

### Multilateral CRS pipeline
The multilateral script:
- loads CRS Parquet data
- filters to multilateral donor entities
- applies the same classification logic as the donor script
- creates child-focus aggregates by donor and year
- calculates child-focus shares
- exports aggregated outputs

### Child-focused ODA summary pipeline
The CF summary script (`UNICEF CF Summary 04-2026.R`):
- loads CRS Parquet data
- filters early to DAC and EU Institutions donors using a reference file
- filters to ODA flows and years from 2014 onward
- applies the same classification logic as the donor script
- applies the Australia SDG exclusion rule and stores the adjusted summary flag as `c_summary_australia_sdg_adjusted`
- aggregates to donor × year pivot tables covering total ODA, child-focused ODA, child-focused share of total ODA, and child-focused share of all-donor child-focused ODA
- builds sector-level breakdowns for education, health, humanitarian, WATSAN, nutrition, and social protection
- exports a 12-tab Excel workbook and a supporting CSV to `Output/`
- optionally appends supplementary reference fields (these are add-ons; see Reference files above)

### MUMS imputation pipeline
The MUMS script:
- loads core contribution data
- maps MUMS channels to CRS multilateral donors
- joins CRS-derived multilateral child-focus shares
- computes imputed child-focused amounts
- exports detailed and aggregated outputs

### Execution order for multilateral imputation
The imputed multilateral workflow is a two-step sequence:

1. run the multilateral CRS script to produce multilateral donor-year child-focus shares (`c_crs_multi_aggregated_parquet_wide.csv`)
2. run the MUMS script, which combines:
	- that multilateral CRS output, and
	- the bespoke bridge file `MUMS CRS Reference.csv` that maps MUMS channel naming to CRS donor entities

The donor CRS script is not an input to this multilateral imputation sequence.

---

## Classification Framework

## 1. Purpose Codes

Certain CRS purpose codes are treated as directly child-relevant and therefore trigger `c_purpose = "Y"`.

Included purpose codes in the current iteration:
- `11110` Education policy and administrative management
- `11120` Education facilities and training
- `11130` Teacher training
- `11182` Educational research
- `11220` Primary education
- `11231` Basic life skills for youth
- `11240` Early childhood education
- `11250` School feeding
- `11260` Lower secondary education
- `11320` Upper secondary education
- `11330` Vocational training
- `13020` Reproductive health care
- `13030` Family planning
- `15261` Child soldiers (prevention and demobilisation)

Excluded purpose codes include:
- `14020` Water supply and sanitation - large systems
- `14021` Water supply - large systems
- `14022` Sanitation - large systems
- `14030` Basic drinking water supply and basic sanitation
- `14031` Basic drinking water supply
- `14032` Basic sanitation
- `11232` Primary education equivalent for adults
- `16010` Social protection

These exclusions reflect an explicit targeting framework rather than a welfare-incidence approach.

---

## 2. Channels of Delivery

`c_channel = "Y"` is assigned using two mechanisms:

1. direct match against selected `channel_code` values
2. keyword matching on `channel_reported_name`

Selected `channel_code` values in the current iteration are:
- `21011` Global Campaign for Education
- `21505` Save the Children
- `22502` Save the Children - donor country office
- `21010` Forum for African Women Educationalists
- `41122` UNICEF
- `47501` Global Partnership for Education
- `47147` International Finance Facility for Education

This is used to identify organisations with a strong child-related mandate, including UNICEF and selected education- and child-focused organisations.

---

## 3. Donor-Type Code

`c_donor_type = "Y"` is currently assigned when `donor_code == 963`, corresponding to UNICEF.

---

## 4. Policy Marker

`c_marker = "Y"` is assigned when the `rmnch` marker equals:
- `1` = significant
- `2` = principal

---

## 5. SDG Focus

`c_sdg = "Y"` is assigned when the `sd_gfocus` field contains one or more exact-token matches from the selected list:
- `3.1` Reduce maternal mortality
- `3.2` End preventable deaths of newborns and children under 5
- `3.7` Universal access to sexual and reproductive health-care services
- `4.1` Free, equitable and quality primary and secondary education
- `4.2` Access to quality early childhood development and pre-primary education
- `4.a` Build and upgrade education facilities that are child-sensitive and inclusive
- `5.3` Eliminate child, early and forced marriage and female genital mutilation
- `8.7` Eradicate forced labour, modern slavery, human trafficking and child labour
- `16.2` End abuse, exploitation, trafficking and violence against children

Matching is exact-token rather than substring-based. This avoids false matches such as `3.1` incorrectly matching `3.10`.

---

## 6. Keyword Methodology

### Text preparation
Keyword matching is applied to a combined text field built from:
- `short_description`
- `project_title`
- `long_description`

Before matching:
- text fields are concatenated into `Combined_Description`
- punctuation is stripped
- extra whitespace is normalized
- text is transliterated with `latin-ascii` for accent-insensitive matching

### Regex design principles
The keyword methodology uses regex patterns designed to balance recall and precision.

Current design features include:
- multilingual keyword dictionaries
- optional hyphen/space flexibility using patterns such as `[ -]?`
- selective use of word boundaries (`\b`) where substring false positives are likely
- explicit exclusion of selected high-risk terms

Translations are included for French, Spanish, German and Dutch because a number of CRS donors provide descriptive text in those languages. To improve precision, shorter or potentially ambiguous terms use word boundaries so they match complete words rather than unrelated substrings. The regex patterns also allow common variation in spacing and hyphenation across donor reporting styles. All matching is case-insensitive, and both text and keywords are accent-normalized before detection so that capitalization and diacritical variation do not affect results.

### Language-specific gating
English is applied to all donors.

Other languages are only applied to donors likely to report in those languages. This reduces cross-language false positives and also reduces unnecessary regex evaluation.

#### English
Applied to all donors.

#### French
Applied only to the following donor codes:
- `4` France
- `2` Belgium
- `22` Luxembourg
- `301` Canada
- `5` Germany
- `918` EU Institutions
- `11` Switzerland
- `913` African Development Bank
- `914` African Development Fund
- `26` Monaco
- `988` IFAD
- `7` Netherlands
- `932` Food and Agriculture Organisation
- `1401` WTO - International Trade Centre
- `1020` Central Emergency Response Fund
- `971` UNAIDS
- `923` UN Peacebuilding Fund
- `940` International Labour Organisation
- `959` UNDP

#### Spanish
Applied only to the following donor codes:
- `50` Spain
- `910` Central American Bank for Economic Integration
- `909` Inter-American Development Bank
- `1015` Development Bank of Latin America
- `923` UN Peacebuilding Fund
- `918` EU Institutions
- `959` UNDP

#### Dutch
Applied only to:
- `7` Netherlands

#### German
Applied only to:
- `5` Germany

### Precision exclusions
The following keywords are intentionally excluded due to false-positive risk:
- Dutch `kind`
- German `Kind`
- German `Kita`

### Recall-oriented terms under review
Some terms are retained for recall but may be reconsidered later if precision concerns increase.

Examples include:
- English: `youth`, `youthful`, `young person`
- French: `jeunesse`, `jeune`, `jeunes`
- Spanish: `juventud`, `joven`, `jovenes`
- Dutch: `jeugd`, `jongere`, `jongeren`
- German: `Jugend`, `Jugendliche`, `jugendlich`

### Additional WATSAN rule
A supplementary keyword rule is applied for water and sanitation purpose codes:
- `14020` Water supply and sanitation - large systems
- `14021` Water supply - large systems
- `14022` Sanitation - large systems
- `14030` Basic drinking water supply and basic sanitation
- `14031` Basic drinking water supply
- `14032` Basic sanitation

For these records, `c_keyword = "Y (watsan additional)"` is assigned if school-equivalent terms are detected in English, French, or Spanish.

This rule is based on qualitative review and is intended to improve accuracy where water and sanitation activities are clearly school-related.

### Optional matched-keyword extraction
When enabled, the scripts can also produce a `keywords_matched` field listing the matched terms for records flagged through the keyword logic.

---

## Summary Classification

The summary classification flag is:
- `c_summary = "Y"` when any of the component flags are positive

These component flags are:
- `c_purpose`
- `c_channel`
- `c_donor_type`
- `c_marker`
- `c_keyword`
- `c_sdg`

This means the summary flag is inclusive: a record only needs to satisfy one identification dimension to be counted as child-focused at summary level.

### Donor-specific SDG exclusion rule

For selected donors, a precision adjustment can be applied: where a record is flagged **only** by `c_sdg` (with no supporting flag from any other dimension), `c_summary` is left blank rather than set to `"Y"`. This is configured via the `donors_apply_sdg_exclusion_rule` setting in the donor script.

This rule was introduced for Australia, where SDG-only matches were found to materially inflate reported child-focused totals, with many such records appearing to reflect broad or indirect rather than specifically child-targeted activities. In the CF summary script, the equivalent rule is applied directly in code and the adjusted flag is stored as `c_summary_australia_sdg_adjusted` to distinguish it from the unmodified `c_summary`.

For all donors not listed in `donors_apply_sdg_exclusion_rule`, the standard inclusive rule applies: a positive `c_sdg` alone is sufficient to set `c_summary = "Y"`.

---

## Multilateral Imputation Method

The multilateral estimation stage proceeds in two parts:

1. calculate a CRS-derived child-focus share for each multilateral donor
2. apply that share to MUMS core contribution amounts

The child-focus share used is a **fixed 5-year pooled average (2020–2024)**, calculated per multilateral donor across all CRS records in that period. It is stored as `CRS_child_focus_pct_5yr_avg_2020_2024` in the output. This share is treated as a single representative estimate per donor rather than as an annual time-varying figure.

Formula:

$$
\text{Imputed child-focused amount} = \text{CRS child-focus share}_{\text{5yr avg 2020–2024}} \times \text{MUMS core contribution amount}
$$

This produces estimated child-focused multilateral ODA amounts by donor and year.

### Fallback logic for missing year rows

Some multilateral donors have gaps in annual CRS reporting (i.e. no CRS record for a given year). For these cases, the primary year + donor code join will not find a match. A fallback donor-code-only merge is applied to backfill `CRS_child_focus_pct_5yr_avg_2020_2024` for those rows. Annual CRS volume fields (`CRS_usd_defl_*`) remain `NA` for missing year rows, as imputing annual amounts would not be appropriate. The 5-year average share is considered valid to apply across all years since it is a fixed reference estimate per donor.

---

## Reproducibility Notes

The methodology is coded directly in R scripts, which makes the pipeline deterministic and auditable.

Current strengths:
- fully scripted workflow
- explicit code lists and keyword dictionaries
- documented rule changes and exclusions in code comments
- consistent methodology across donor and multilateral processing

Current limitations being addressed:
- reference files and code lists require periodic maintenance as OECD taxonomies and country classifications evolve
- keyword dictionaries and donor-language gates require ongoing precision/recall testing as new data years are added
- some legacy local script variants may still contain machine-specific paths and are not part of the portable GitHub release

---

## Planned Improvements

Planned next steps include:
- continued refinement of keyword dictionaries
- expansion of `channel_reported_name` matching to include additional French variants and naming forms (for example, "Partenariat mondial éducation")
- continued review of borderline recall-oriented terms
- consideration of budget identifier voluntary codes as a supplementary classification input (for example, `72012` Education in emergencies and `16015` Social services, including youth development and women/children); activities under these codes are often relevant, but donor use is not yet wide or consistent, so this can improve coverage but is not a comprehensive representation of spending in these areas
- consideration of adding purpose code `12240` (Basic nutrition) to the child-focused purpose code review set
- consideration of including the nutrition policy marker as a supplementary signal, with particular attention to principal-marked activities
- consideration of adding nutrition-related keywords to the multilingual keyword dictionaries, subject to precision and false-positive testing
- reconsideration of SDG focus as a standalone child-focus trigger, because records often reference multiple SDGs and can produce very partial matches with no other child-focused indication; consider restricting SDG-only inclusion to records where the SDG set is fully child-related
- Comments from PPR Asia Pacific Pillar indicate that additional potentially child-focused codes could be considered in future iterations, including `72011` Basic health care services in emergencies (including SAM treatment), `15180` Ending violence against women and girls, `12240` Basic nutrition (including IYCF), `12220` Basic health care (including vaccines), and `72012` Education in emergencies; note that `12240` and `72012` are already listed above as codes for recommended inclusion. While some may be partly captured through other dimensions (for example RMNCH marker or SDG focus), inclusion may improve upper-bound child-focused estimates.

---

## Limitations

### Intent-based identification and scope
The methodology is designed to capture explicit donor intent to support children and child rights, using purpose codes, channels, policy markers, SDG focus, and keywords. This approach does not estimate welfare incidence, so activities with potential child benefits may be excluded if not explicitly signalled in reporting fields. The requirement for a clear trigger means some relevant projects may be missed when donor descriptions lack detail.

### Quantification of partial focus
Some included projects are only partly child-focused (e.g., those with a significant policy marker or a single keyword match in a long description). This makes precise attribution challenging, and results should be interpreted as indicative upper-bound estimates of intent-based child focus, not exact child-attributable shares.

### Donor reporting heterogeneity
Differences in donor reporting practices and descriptive detail can affect classification and comparability. Some donors provide more limited information, which impacts keyword detection and the identification of child-focused activities. This is also relevant for multilateral calculations, where descriptive fields and marker use may be sparse.
For Afghanistan, channel and project-description detail is removed across donor reporting for security-related reasons, which lowers detectable child-focused signals and can understate measured returns. A similar, though less universal, reporting pattern appears in some Ukraine records for selected donors (for example, Japan, Netherlands and France), where limited descriptive detail can likewise reduce detection.

### Child protection coding coverage
Comments from PPR Asia Pacific Pillar in Tokyo suggest that child protection assistance can be difficult to capture using existing CRS purpose codes. This may lead to under-capture of child protection-relevant support in the analysis.

### Keyword-based limits
Keyword matching improves coverage but is rule-based and does not capture full semantic meaning. Ambiguous or limited descriptions can lead to misclassification or missed activities.

### Ongoing and future improvements
- Continued review of borderline cases and keyword lists
- Exploration of AI/NLP methods for improved text classification and relevance scoring
- Integration of improved reporting standards as they become available (e.g., dedicated child-focus fields or standardized thematic tags)

These limitations are documented and remain active areas for review and discussion as the methodology evolves.

## Interpretation

This framework is intended to identify likely child-focused activities in a transparent and reproducible way. It is a rules-based approximation rather than a perfect substantive measure of child benefit. Results should therefore be interpreted as methodology-based estimates derived from explicit classification rules.
