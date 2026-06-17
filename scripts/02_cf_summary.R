# UNICEF All-Donors Pivot by Year CRS Child-Focus Script (23-03-2026)
# Loads CRS parquet data, applies child-focus classification, and exports all-donor × year pivot table.
# Rows: All donors | Columns: Years 2014-2024 | Values: Sum of child-focused disbursements

# Helper function to ensure packages are installed and loaded
ensure_package <- function(package_name) {
  if (!requireNamespace(package_name, quietly = TRUE)) {
    message("Installing package: ", package_name)
    install.packages(package_name, dependencies = TRUE)
  }
  library(package_name, character.only = TRUE)
}

# Load necessary libraries
ensure_package("readr")
ensure_package("dplyr")
ensure_package("stringr")
ensure_package("stringi")
ensure_package("arrow")
ensure_package("tibble")
ensure_package("tidyr") # For pivot_wider
ensure_package("openxlsx") # For Excel workbook output

# Set locale to UTF-8 for special character handling
tryCatch(Sys.setlocale("LC_ALL", "en_US.UTF-8"), error = function(e) message("Could not set locale to en_US.UTF-8."))


# --- User-configurable settings ---
filter_by_oda <- TRUE
filter_by_year_ge_2014 <- TRUE
extract_matched_keywords <- FALSE
include_non_cf_breakdowns <- TRUE  # Set TRUE to add Non-CF by Sector/Region/Income Group tabs

# ----------------------------------------------------------------------------------
# --- Core Data Loading Logic ---
# ----------------------------------------------------------------------------------

parquet_file_path <- './input/CRS.parquet'

if (!file.exists(parquet_file_path)) {
  stop(paste0("Parquet file not found: '", parquet_file_path, "'. Please check the path."))
}

# Load the Parquet file
crs_data_original_names <- arrow::read_parquet(parquet_file_path)

# Keep only the columns used downstream to reduce memory pressure
needed_input_cols <- c(
  "flow_name", "year", "purpose_code", "sector_code", "channel_code", "channel_reported_name",
  "donor_code", "donor_name", "recipient_code", "rmnch", "nutrition", "short_description", "project_title",
  "long_description", "sd_gfocus", "usd_disbursement_defl"
)

crs_data_original_names <- crs_data_original_names %>%
  select(any_of(needed_input_cols))

# --- FILTER TO DAC AND EU DONORS ONLY (applied early to save processing time) ---
donor_type_ref_path <- './input/reference_files/donor_type_ref.csv'
donor_type_ref <- read_csv(donor_type_ref_path, show_col_types = FALSE)
dac_eu_donor_codes <- donor_type_ref %>%
  filter(donor_type_DAC_EU == "DAC and EU Institutions") %>%
  pull(donor_code) %>%
  as.character()
crs_data_original_names <- crs_data_original_names %>%
  filter(as.character(donor_code) %in% dac_eu_donor_codes)

gc()
message("CRS data loaded, trimmed to required columns, and filtered to DAC and EU donors.")


# ----------------------------------------------------------------------------------
# --- BEGIN DATA PROCESSING LOGIC ---
# ----------------------------------------------------------------------------------

# --- EARLY FILTERING TO SAVE MEMORY ---

# Add IsODA column
if ("flow_name" %in% names(crs_data_original_names)) {
  flowtype_oda_lookup <- tribble(
    ~flow_name, ~IsODA_value,
    "ODA Grants", "ODA",
    "ODA Loans", "ODA",
    "Equity Investment", "ODA",
    "Other Official Flows (non Export Credit)", "Other Official Flows",
    "Private Development Finance", "Private Development Assistance",
    "Private Sector Instruments (PSI)", "Private Sector Instruments (PSI)"
  )
  
  crs_data_original_names <- crs_data_original_names %>%
    left_join(flowtype_oda_lookup, by = "flow_name") %>%
    mutate(IsODA = ifelse(is.na(IsODA_value), "", IsODA_value)) %>%
    select(-IsODA_value)
} else {
  crs_data_original_names <- crs_data_original_names %>% mutate(IsODA = "")
}

# Early ODA filter
if (filter_by_oda && "IsODA" %in% names(crs_data_original_names)) {
  crs_data_original_names <- crs_data_original_names %>% filter(IsODA == "ODA")
}

# Early year filter
if (filter_by_year_ge_2014 && "year" %in% names(crs_data_original_names)) {
  crs_data_original_names <- crs_data_original_names %>%
    mutate(year = as.numeric(year)) %>%
    filter(year >= 2014)
}


# Ensure classification input columns exist (create safe defaults if missing)
classification_input_defaults <- list(
  purpose_code = "",
  sector_code = "",
  channel_code = "",
  channel_reported_name = "",
  donor_code = "",
  donor_name = "",
  rmnch = ""
)

for (col_name in names(classification_input_defaults)) {
  if (!(col_name %in% names(crs_data_original_names))) {
    warning("      - Missing column '", col_name, "'. Creating default empty column.")
    crs_data_original_names[[col_name]] <- classification_input_defaults[[col_name]]
  }
}


# --- Add Combined_Description column ---
description_cols_original <- c("short_description", "project_title", "long_description")

if (all(description_cols_original %in% names(crs_data_original_names))) {
  crs_data_original_names <- crs_data_original_names %>%
    mutate(
      Combined_Description = paste(
        coalesce(.[["short_description"]], ""),
        coalesce(.[["project_title"]], ""),
        coalesce(.[["long_description"]], ""),
        sep = " "
      ),
      Combined_Description = stringi::stri_replace_all_regex(Combined_Description, "[[:punct:]]", " "),
      Combined_Description = stringi::stri_replace_all_regex(Combined_Description, "\\s+", " "),
      Combined_Description = trimws(Combined_Description),
      Combined_Description_ascii = stringi::stri_trans_general(Combined_Description, "latin-ascii"),
      channel_reported_name_ascii = stringi::stri_trans_general(coalesce(channel_reported_name, ""), "latin-ascii"),
      donor_code_chr = coalesce(as.character(donor_code), ""),
      purpose_code_chr = as.character(purpose_code)
    )
} else {
  missing_desc_cols <- description_cols_original[!(description_cols_original %in% names(crs_data_original_names))]
  warning("      - The following description columns were NOT found: ", paste(missing_desc_cols, collapse = ", "), ". Creating empty 'Combined_Description'.")
  crs_data_original_names <- crs_data_original_names %>%
    mutate(
      Combined_Description = "",
      Combined_Description_ascii = "",
      channel_reported_name_ascii = stringi::stri_trans_general(coalesce(channel_reported_name, ""), "latin-ascii"),
      donor_code_chr = coalesce(as.character(donor_code), ""),
      purpose_code_chr = as.character(purpose_code)
    )
}

message("Text fields prepared for child-focus classification.")

# ----------------------------------------------------------------------------------
# --- CLASSIFICATION COLUMNS ---
# ----------------------------------------------------------------------------------

code_lists <- list(
  purpose = c(
    "11110", "11120", "11130", "11182", "11220", "11231", "11240", "11250",
    "11260", "11320", "11330", "13020", "13030", "15261"
  ),
  channel = c(
    "21011", "21505", "22502", "21010", "41122", "47501", "47147"
  ),
  channel_rep_name_keywords = c(
    "Save the Children",
    "Global Partnership for Education",
    "Forum for African Women Educationalists",
    "International Finance Facility for Education",
    "UNICEF",
    "United Nations Children's Fund"
  ),
  donor_type = c(
    "963" # UNICEF
  )
)

sdg_focus_targets <- c("3.1", "3.2", "3.7", "4.1", "4.2", "4.a", "5.3", "8.7", "16.2")
sdg_focus_targets <- tolower(trimws(sdg_focus_targets))

english_keywords <- c(
  "child", "children", "childhood", "\\binfant\\b", "\\binfants\\b", "infancy",
  "\\bboy\\b", "\\bboys\\b", "boyhood", "girl", "girls", "girlhood",
  "adolescent", "adolescents", "youth", "youths", "youthful",
  "young person", "youngest", "teenager", "orphan",
  "toddler", "toddlers", "baby", "babies", "under[ -]?5",
  "early[ -]?brain", "neuro[ -]?development", "brain[ -]?development",
  "neonatal", "birth", "antenatal",
  "early[ -]?learning", "pre[ -]?school",
  "elementary[ -]?school", "primary[ -]?school", "secondary[ -]?school",
  "primary[ -]?education", "secondary[ -]?education",
  "kindergarten", "nursery", "new[ -]?born"
)

french_keywords <- c(
  "enfant", "enfants", "\\bnourrisson\\b", "\\bnourrissons\\b", "garçon", "garçons",
  "\\bfille\\b", "\\bfilles\\b", "adolescent", "adolescents", "adolescente", "adolescentes",
  "jeunesse", "\\bjeune\\b", "\\bjeunes\\b", "plus[ -]?jeune", "jeune personne", "jeunes personnes",
  "\\borphelin\\b", "\\borpheline\\b", "\\borphelins\\b", "\\borphelines\\b",
  "cerveau[ -]?précoce", "neuro[ -]?développement", "développement[ -]?cérébral",
  "\\bnaissance\\b", "prénatal", "apprentissage[ -]?précoce", "préscolaire",
  "école[ -]?élémentaire", "école[ -]?maternelle", "école[ -]?préscolaire", "école[ -]?primaire", "école[ -]?secondaire",
  "enseignement[ -]?primaire", "enseignement[ -]?secondaire",
  "jardin[ -]?d[ -]?enfants", "crèche", "crèches",
  "nouveau[ -]?né", "nouveau[ -]?née", "nouveaux[ -]?nées",
  "enfance", "adolescence", "mineur", "maternel", "maternelle",
  "néonatal", "infantile", "mille[ -]?premiers[ -]?jours",
  "nouveaux[ -]?né", "nouveaux[ -]?nés",
  "bambin", "bambins", "\\bbébé\\b", "\\bbébés\\b", "moins[ -]?de[ -]?5", "moins de cinq ans",
  "moins de cinq"
)

spanish_keywords <- c(
  "\\bniños\\b","\\bniña\\b", "\\bniñas\\b", "\\binfante\\b", "\\binfantes\\b", "\\bbebé\\b", "\\bbebés\\b",
  "\\bchico\\b", "\\bchicos\\b", "\\bchica\\b", "\\bchicas\\b", "adolescente", "adolescentes",
  "juventud", "\\bjoven\\b", "\\bjovenes\\b", "más joven", "persona joven", "personas jovenes",
  "niñez", "infancia", "infantil", "niño pequeño", "niños pequeños", "niña pequeña", "niñas pequeñas",
  "\\bhuérfano\\b", "\\bhuérfana\\b", "\\bhuérfanos\\b", "\\bhuérfanas\\b",
  "cerebro[ -]?temprano", "neuro[ -]?desarrollo", "desarrollo[ -]?cerebral",
  "neonatal", "nacimiento", "prenatal", "aprendizaje[ -]?temprano", "pre[ -]?escolar",
  "pre[ -]?escolares",
  "escuela[ -]?elemental", "escuela[ -]?primaria", "escuela[ -]?secundaria", "educación[ -]?primaria", "educación[ -]?secundaria",
  "jardín[ -]?de[ -]?infantes", "guardería", "guarderías",
  "recién[ -]?nacido", "recién[ -]?nacida", "recién[ -]?nacidos", "recién[ -]?nacidas",
  "menor[ -]?de[ -]?5", "menores[ -]?de[ -]?5", "menor de cinco años"
)

dutch_keywords <- c(
  "kinderen", "kindertijd", "jeugd",
  "zuigeling", "zuigelingen", "babytijd", "zuigelingenleeftijd",
  "jongen", "jongens", "jongensjaren", "meisje", "meisjes", "meisjesjaren",
  "adolescent", "jongere", "adolescenten", "jongeren",
  "jeugdig", "jongste", "jonge mensen",
  "tiener", "\\bwees\\b", "peuter", "peuters", "dreumes", "dreumesen",
  "onder 5 jaar",
  "vroege hersenontwikkeling", "neurologische ontwikkeling", "hersenontwikkeling",
  "neonataal", "geboorte", "prenataal", "voor de geboorte",
  "vroeg leren", "vroege ontwikkeling", "voorschoolse ontwikkeling", "vroegschoolse educatie",
  "voorschool", "kleuterschool", "voorschoolse opvang", "peuterschool",
  "basisschool", "lagere school", "middelbare school", "basisonderwijs",
  "voortgezet onderwijs", "secundair onderwijs",
  "kinderdagverblijf", "\\bcreche\\b", "kinderopvang", "pasgeborene",
  "borstvoeding", "moedermelk", "eerste duizend dagen"
)

german_keywords <- c(
  "Kinder", "Kindheit",
  "Säugling", "Säuglinge", "Säuglingsalter",
  "Junge", "Jungen", "Mädchen",
  "Jugendlicher", "Jugendliche", "Jugend", "jugendlich", "die Jugend",
  "jüngste", "junge Menschen", "Teenager", "\\bWaise\\b",
  "Kleinkind", "Kleinkinder", "unter 5 Jahren",
  "frühe Gehirnentwicklung", "neurologische Entwicklung", "Neuroentwicklung",
  "Gehirnentwicklung", "Entwicklung des Gehirns",
  "neonatal", "Geburt", "pränatal", "frühkindliche Bildung",
  "Vorschule", "Grundschule", "Primarschule", "Sekundarschule", "weiterführende Schule",
  "Primarbildung", "Grundschulbildung", "Sekundarbildung",
  "Kindergarten", "Kinderkrippe", "Neugeborenes"
)

# Build regex patterns
core_keywords <- c(english_keywords)
core_keywords_normalized <- stringi::stri_trans_general(core_keywords, "latin-ascii")
french_keywords_normalized <- stringi::stri_trans_general(french_keywords, "latin-ascii")
dutch_keywords_normalized <- stringi::stri_trans_general(dutch_keywords, "latin-ascii")
german_keywords_normalized <- stringi::stri_trans_general(german_keywords, "latin-ascii")
spanish_keywords_normalized <- stringi::stri_trans_general(spanish_keywords, "latin-ascii")

keyword_pattern_core <- paste(core_keywords_normalized, collapse = "|")
keyword_pattern_french <- paste(french_keywords_normalized, collapse = "|")
keyword_pattern_dutch <- paste(dutch_keywords_normalized, collapse = "|")
keyword_pattern_german <- paste(german_keywords_normalized, collapse = "|")
keyword_pattern_spanish <- paste(spanish_keywords_normalized, collapse = "|")
channel_name_pattern <- paste0("(?i)(", paste(gsub(" ", "[ -]?", code_lists$channel_rep_name_keywords), collapse = "|"), ")")

donor_codes_french <- c("4", "2", "22", "301", "5", "918", "11", "913", "914", "26", "988", "7", "932", "1401", "1020", "971", "923", "940", "959")
donor_code_netherlands <- "7"
donor_code_germany <- "5"
donor_codes_spanish <- c("50", "910", "909", "1015", "923", "918", "959")

watsan_additional_purpose_codes <- c("14020", "14021", "14022", "14030", "14031", "14032")
watsan_school_pattern <- "\\bschools?\\b|\\becoles?\\b|\\bescuelas?\\b"


# Create classification columns
message("Applying child-focus classification rules...")

crs_data_original_names <- crs_data_original_names %>%
  mutate(
    has_channel_name_match = stringi::stri_detect_regex(channel_reported_name_ascii, channel_name_pattern),
    has_core_keywords = stringi::stri_detect_regex(Combined_Description_ascii, keyword_pattern_core, case_insensitive = TRUE),
    has_french_keywords = donor_code_chr %in% donor_codes_french &
      stringi::stri_detect_regex(Combined_Description_ascii, keyword_pattern_french, case_insensitive = TRUE),
    has_dutch_keywords = donor_code_chr == donor_code_netherlands &
      stringi::stri_detect_regex(Combined_Description_ascii, keyword_pattern_dutch, case_insensitive = TRUE),
    has_german_keywords = donor_code_chr == donor_code_germany &
      stringi::stri_detect_regex(Combined_Description_ascii, keyword_pattern_german, case_insensitive = TRUE),
    has_spanish_keywords = donor_code_chr %in% donor_codes_spanish &
      stringi::stri_detect_regex(Combined_Description_ascii, keyword_pattern_spanish, case_insensitive = TRUE),
    has_watsan_school_match = purpose_code_chr %in% watsan_additional_purpose_codes &
      stringi::stri_detect_regex(Combined_Description_ascii, watsan_school_pattern, case_insensitive = TRUE)
  ) %>%
  mutate(
    c_purpose = case_when(
      purpose_code_chr %in% code_lists$purpose ~ "Y",
      TRUE ~ ""
    ),
    c_channel = case_when(
      channel_code %in% code_lists$channel ~ "Y",
      has_channel_name_match ~ "Y",
      TRUE ~ ""
    ),
    c_donor_type = case_when(
      donor_code_chr %in% code_lists$donor_type ~ "Y",
      TRUE ~ ""
    ),
    c_marker = case_when(
      rmnch %in% c("1", "2") ~ "Y",
      TRUE ~ ""
    ),
    c_keyword = case_when(
      has_core_keywords | has_french_keywords | has_dutch_keywords |
        has_german_keywords | has_spanish_keywords ~ "Y",
      has_watsan_school_match ~ "Y (watsan additional)",
      TRUE ~ ""
    )
  )

crs_data_original_names <- crs_data_original_names %>%
  mutate(c_keyword = if_else(c_keyword == "Y (watsan additional)", "Y", c_keyword)) %>%
  select(-any_of(c(
    "Combined_Description",
    "Combined_Description_ascii",
    "channel_reported_name_ascii",
    "donor_code_chr",
    "purpose_code_chr",
    "has_channel_name_match",
    "has_core_keywords",
    "has_french_keywords",
    "has_dutch_keywords",
    "has_german_keywords",
    "has_spanish_keywords",
    "has_watsan_school_match"
  )))

gc()
message("Classification complete.")

# c_sdg from sd_gfocus values
if ("sd_gfocus" %in% names(crs_data_original_names)) {
  crs_data_original_names <- crs_data_original_names %>%
    mutate(
      sd_gfocus_clean = tolower(trimws(as.character(sd_gfocus))),
      c_sdg = ifelse(
        vapply(
          strsplit(gsub("\\s*[,;|/]\\s*", ",", sd_gfocus_clean), ","),
          function(tokens) any(tokens %in% sdg_focus_targets),
          logical(1)
        ),
        "Y",
        ""
      )
    ) %>%
    select(-sd_gfocus_clean)
} else {
  crs_data_original_names <- crs_data_original_names %>% mutate(c_sdg = "")
}

# Create c_summary master flag
crs_data_original_names <- crs_data_original_names %>%
  mutate(c_summary = case_when(
    c_purpose == "Y" | c_channel == "Y" | c_marker == "Y" | c_keyword == "Y" | c_donor_type == "Y" | c_sdg == "Y" ~ "Y",
    TRUE ~ ""
  )) %>%
  # Australia-specific adjustment: remove rows that are flagged only by SDG,
  # while keeping rows where Australia is flagged by any other child-focus rule.
  mutate(c_summary_australia_sdg_adjusted = case_when(
    stringi::stri_trans_general(coalesce(donor_name, ""), "latin-ascii") == "Australia" &
      c_sdg == "Y" & c_purpose != "Y" & c_channel != "Y" & c_marker != "Y" &
      c_keyword != "Y" & c_donor_type != "Y" ~ "",
    c_summary == "Y" ~ "Y",
    TRUE ~ ""
  ))


# ----------------------------------------------------------------------------------
# --- SECTOR CLASSIFICATION (using purpose_ref lookup) ---
# ----------------------------------------------------------------------------------

purpose_ref_path <- './input/reference_files/purpose_ref.csv'
purpose_ref <- read_csv(purpose_ref_path, show_col_types = FALSE)

# Build sector lookup from the "Aggregate sectors 1" column
sector_lookup <- purpose_ref %>%
  select(purpose_code, sector = `Aggregate sectors 1`) %>%
  mutate(purpose_code = as.character(purpose_code))

# Load region lookup from Recipients_regions_ref (also carries de_recipientcode for income group join)
region_ref_path <- './input/reference_files/Recipients_regions_ref.csv'
region_ref <- read_csv(region_ref_path, show_col_types = FALSE)
region_lookup <- region_ref %>%
  select(recipient_code, region = `Region aggregated 1`, de_recipientcode) %>%
  mutate(recipient_code = as.character(recipient_code)) %>%
  distinct(recipient_code, .keep_all = TRUE)

# Load income group lookup from income_groups.csv (keyed on ISO3 de_recipientcode)
income_groups_ref_path <- './input/reference_files/income_groups.csv'
income_groups_ref <- read_csv(income_groups_ref_path, show_col_types = FALSE)
income_group_lookup <- income_groups_ref %>%
  select(de_recipientcode = Code, income_group = `Income group`) %>%
  distinct(de_recipientcode, .keep_all = TRUE)

# Join sector to main data
crs_data_original_names <- crs_data_original_names %>%
  mutate(purpose_code_chr = as.character(purpose_code)) %>%
  left_join(sector_lookup, by = c("purpose_code_chr" = "purpose_code")) %>%
  select(-purpose_code_chr)

# Join region (and de_recipientcode) to main data, then join income group
crs_data_original_names <- crs_data_original_names %>%
  mutate(recipient_code_chr = as.character(recipient_code)) %>%
  left_join(region_lookup, by = c("recipient_code_chr" = "recipient_code")) %>%
  select(-recipient_code_chr) %>%
  left_join(income_group_lookup, by = "de_recipientcode") %>%
  mutate(income_group = coalesce(income_group, "Regional and unspecified")) %>%
  select(-de_recipientcode)

# Ensure nutrition column exists
if (!"nutrition" %in% names(crs_data_original_names)) {
  crs_data_original_names <- crs_data_original_names %>% mutate(nutrition = NA_character_)
}

# Create sector flags
crs_data_original_names <- crs_data_original_names %>%
  mutate(
    is_health = sector == "Health",
    is_humanitarian = sector == "Humanitarian",
    is_education = sector == "Education",
    is_watsan = sector == "Water and sanitation",
    is_basic_nutrition = as.character(purpose_code) == "12240",
    is_nutrition = as.character(purpose_code) == "12240" | as.character(nutrition) %in% c("1", "2"),
    is_social_protection = as.character(purpose_code) == "16010"
  )

message("Sector classifications applied.")

# ----------------------------------------------------------------------------------
# --- PIVOT TABLE: ALL DONORS × YEAR WITH CHILD-FOCUSED DISBURSEMENTS ---
# ----------------------------------------------------------------------------------

required_output_cols <- c("donor_code", "donor_name", "year", "usd_disbursement_defl")
missing_required_output_cols <- setdiff(required_output_cols, names(crs_data_original_names))

if (length(missing_required_output_cols) > 0) {
  stop(
    "Missing required column(s) for pivot output: ",
    paste(missing_required_output_cols, collapse = ", "),
    ". Please verify CRS.parquet schema."
  )
}

crs_data_original_names <- crs_data_original_names %>%
  mutate(
    year = suppressWarnings(as.integer(year)),
    usd_disbursement_defl = suppressWarnings(as.numeric(usd_disbursement_defl))
  )

# Overall bilateral ODA totals by donor across the included years
# (used for donor share, total ODA volume, and child-focused share calculations)
required_years <- as.character(2014:2024)

# --- Total bilateral ODA by donor × year ---
total_oda_long <- crs_data_original_names %>%
  group_by(donor_code, donor_name, year) %>%
  summarise(total_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  mutate(year = as.character(year))

donor_total_oda <- total_oda_long %>%
  pivot_wider(names_from = year, values_from = total_oda, values_fill = 0)
for (yr in required_years) {
  if (!yr %in% names(donor_total_oda)) donor_total_oda[[yr]] <- 0
}
donor_total_oda <- donor_total_oda %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- Total ODA share: each donor's % of group total ODA, by year ---
group_year_totals <- total_oda_long %>%
  group_by(year) %>%
  summarise(group_total = sum(total_oda, na.rm = TRUE), .groups = "drop")

donor_oda_share <- total_oda_long %>%
  left_join(group_year_totals, by = "year") %>%
  mutate(share = if_else(group_total > 0, round(100 * total_oda / group_total, 2), NA_real_)) %>%
  select(donor_code, donor_name, year, share) %>%
  pivot_wider(names_from = year, values_from = share, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_oda_share)) donor_oda_share[[yr]] <- NA_real_
}
donor_oda_share <- donor_oda_share %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- Child-focused ODA by donor × year ---
child_oda_long <- crs_data_original_names %>%
  filter(c_summary_australia_sdg_adjusted == "Y") %>%
  group_by(donor_code, donor_name, year) %>%
  summarise(child_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  mutate(year = as.character(year))

donor_child_focus_oda <- child_oda_long %>%
  pivot_wider(names_from = year, values_from = child_oda, values_fill = 0)
for (yr in required_years) {
  if (!yr %in% names(donor_child_focus_oda)) donor_child_focus_oda[[yr]] <- 0
}
donor_child_focus_oda <- donor_child_focus_oda %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# Child-focused share tab uses the same underlying data
# --- CF % of bilateral ODA: donor child-focused as % of own total ODA, by year ---
donor_child_focus_pct <- total_oda_long %>%
  left_join(child_oda_long, by = c("donor_code", "donor_name", "year")) %>%
  mutate(
    child_oda = coalesce(child_oda, 0),
    pct = if_else(total_oda > 0, round(100 * child_oda / total_oda, 2), NA_real_)
  ) %>%
  select(donor_code, donor_name, year, pct) %>%
  pivot_wider(names_from = year, values_from = pct, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_child_focus_pct)) donor_child_focus_pct[[yr]] <- NA_real_
}
donor_child_focus_pct <- donor_child_focus_pct %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- CF % of total CF: donor child-focused as % of DAC+EU group child-focused total, by year ---
group_cf_totals <- child_oda_long %>%
  group_by(year) %>%
  summarise(group_cf_total = sum(child_oda, na.rm = TRUE), .groups = "drop")

donor_cf_share <- child_oda_long %>%
  left_join(group_cf_totals, by = "year") %>%
  mutate(pct = if_else(group_cf_total > 0, round(100 * child_oda / group_cf_total, 2), NA_real_)) %>%
  select(donor_code, donor_name, year, pct) %>%
  pivot_wider(names_from = year, values_from = pct, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_cf_share)) donor_cf_share[[yr]] <- NA_real_
}
donor_cf_share <- donor_cf_share %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# ----------------------------------------------------------------------------------
# --- EX-IDRC CALCULATIONS (excluding sector_code prefix 930*) ---
# ----------------------------------------------------------------------------------

crs_data_ex_idrc <- crs_data_original_names %>%
  filter(!str_starts(coalesce(as.character(sector_code), ""), "930"))

# --- Total bilateral ODA (ex-IDRC) by donor × year ---
total_oda_long_ex_idrc <- crs_data_ex_idrc %>%
  group_by(donor_code, donor_name, year) %>%
  summarise(total_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  mutate(year = as.character(year))

donor_total_oda_ex_idrc <- total_oda_long_ex_idrc %>%
  pivot_wider(names_from = year, values_from = total_oda, values_fill = 0)
for (yr in required_years) {
  if (!yr %in% names(donor_total_oda_ex_idrc)) donor_total_oda_ex_idrc[[yr]] <- 0
}
donor_total_oda_ex_idrc <- donor_total_oda_ex_idrc %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- Total ODA share (ex-IDRC) ---
group_year_totals_ex_idrc <- total_oda_long_ex_idrc %>%
  group_by(year) %>%
  summarise(group_total = sum(total_oda, na.rm = TRUE), .groups = "drop")

donor_oda_share_ex_idrc <- total_oda_long_ex_idrc %>%
  left_join(group_year_totals_ex_idrc, by = "year") %>%
  mutate(share = if_else(group_total > 0, round(100 * total_oda / group_total, 2), NA_real_)) %>%
  select(donor_code, donor_name, year, share) %>%
  pivot_wider(names_from = year, values_from = share, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_oda_share_ex_idrc)) donor_oda_share_ex_idrc[[yr]] <- NA_real_
}
donor_oda_share_ex_idrc <- donor_oda_share_ex_idrc %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- Child-focused ODA (ex-IDRC) by donor × year ---
child_oda_long_ex_idrc <- crs_data_ex_idrc %>%
  filter(c_summary_australia_sdg_adjusted == "Y") %>%
  group_by(donor_code, donor_name, year) %>%
  summarise(child_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  mutate(year = as.character(year))

donor_child_focus_oda_ex_idrc <- child_oda_long_ex_idrc %>%
  pivot_wider(names_from = year, values_from = child_oda, values_fill = 0)
for (yr in required_years) {
  if (!yr %in% names(donor_child_focus_oda_ex_idrc)) donor_child_focus_oda_ex_idrc[[yr]] <- 0
}
donor_child_focus_oda_ex_idrc <- donor_child_focus_oda_ex_idrc %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- CF % of bilateral ODA (ex-IDRC) ---
donor_child_focus_pct_ex_idrc <- total_oda_long_ex_idrc %>%
  left_join(child_oda_long_ex_idrc, by = c("donor_code", "donor_name", "year")) %>%
  mutate(
    child_oda = coalesce(child_oda, 0),
    pct = if_else(total_oda > 0, round(100 * child_oda / total_oda, 2), NA_real_)
  ) %>%
  select(donor_code, donor_name, year, pct) %>%
  pivot_wider(names_from = year, values_from = pct, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_child_focus_pct_ex_idrc)) donor_child_focus_pct_ex_idrc[[yr]] <- NA_real_
}
donor_child_focus_pct_ex_idrc <- donor_child_focus_pct_ex_idrc %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- CF % of total CF (ex-IDRC) ---
group_cf_totals_ex_idrc <- child_oda_long_ex_idrc %>%
  group_by(year) %>%
  summarise(group_cf_total = sum(child_oda, na.rm = TRUE), .groups = "drop")

donor_cf_share_ex_idrc <- child_oda_long_ex_idrc %>%
  left_join(group_cf_totals_ex_idrc, by = "year") %>%
  mutate(pct = if_else(group_cf_total > 0, round(100 * child_oda / group_cf_total, 2), NA_real_)) %>%
  select(donor_code, donor_name, year, pct) %>%
  pivot_wider(names_from = year, values_from = pct, values_fill = NA_real_)
for (yr in required_years) {
  if (!yr %in% names(donor_cf_share_ex_idrc)) donor_cf_share_ex_idrc[[yr]] <- NA_real_
}
donor_cf_share_ex_idrc <- donor_cf_share_ex_idrc %>%
  arrange(desc(rowSums(across(all_of(required_years)), na.rm = TRUE))) %>%
  select(donor_code, donor_name, all_of(required_years))

# --- Child-focused ODA by donor × Aggregate sectors 1 × year ---
donor_sector_year <- crs_data_original_names %>%
  filter(c_summary_australia_sdg_adjusted == "Y") %>%
  mutate(
    sector_label = coalesce(sector, "Unspecified"),
    year = as.character(year)
  ) %>%
  group_by(donor_name, sector_label, year) %>%
  summarise(child_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = year, values_from = child_oda, values_fill = 0) %>%
  rename(Donor = donor_name, Sector = sector_label)

for (yr in required_years) {
  if (!yr %in% names(donor_sector_year)) donor_sector_year[[yr]] <- 0
}
donor_sector_year <- donor_sector_year %>%
  arrange(Donor, Sector) %>%
  select(Donor, Sector, all_of(required_years))

# --- Child-focused ODA by donor × Region aggregated 1 × year ---
donor_region_year <- crs_data_original_names %>%
  filter(c_summary_australia_sdg_adjusted == "Y") %>%
  mutate(
    region_label = coalesce(region, "Unspecified"),
    year = as.character(year)
  ) %>%
  group_by(donor_name, region_label, year) %>%
  summarise(child_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = year, values_from = child_oda, values_fill = 0) %>%
  rename(Donor = donor_name, Region = region_label)

for (yr in required_years) {
  if (!yr %in% names(donor_region_year)) donor_region_year[[yr]] <- 0
}
donor_region_year <- donor_region_year %>%
  arrange(Donor, Region) %>%
  select(Donor, Region, all_of(required_years))

# --- Child-focused ODA by donor × Income group × year ---
donor_income_group_year <- crs_data_original_names %>%
  filter(c_summary_australia_sdg_adjusted == "Y") %>%
  mutate(
    income_group_label = coalesce(income_group, "Regional and unspecified"),
    year = as.character(year)
  ) %>%
  group_by(donor_name, income_group_label, year) %>%
  summarise(child_oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
  pivot_wider(names_from = year, values_from = child_oda, values_fill = 0) %>%
  rename(Donor = donor_name, `Income Group` = income_group_label)

for (yr in required_years) {
  if (!yr %in% names(donor_income_group_year)) donor_income_group_year[[yr]] <- 0
}
donor_income_group_year <- donor_income_group_year %>%
  arrange(Donor, `Income Group`) %>%
  select(Donor, `Income Group`, all_of(required_years))

# --- Non-CF breakdowns (all ODA that is NOT child-focused) ---
if (include_non_cf_breakdowns) {
  non_cf_data <- crs_data_original_names %>% filter(c_summary_australia_sdg_adjusted != "Y")

  donor_sector_year_non_cf <- non_cf_data %>%
    mutate(sector_label = coalesce(sector, "Unspecified"), year = as.character(year)) %>%
    group_by(donor_name, sector_label, year) %>%
    summarise(oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    pivot_wider(names_from = year, values_from = oda, values_fill = 0) %>%
    rename(Donor = donor_name, Sector = sector_label)
  for (yr in required_years) { if (!yr %in% names(donor_sector_year_non_cf)) donor_sector_year_non_cf[[yr]] <- 0 }
  donor_sector_year_non_cf <- donor_sector_year_non_cf %>% arrange(Donor, Sector) %>% select(Donor, Sector, all_of(required_years))

  donor_region_year_non_cf <- non_cf_data %>%
    mutate(region_label = coalesce(region, "Unspecified"), year = as.character(year)) %>%
    group_by(donor_name, region_label, year) %>%
    summarise(oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    pivot_wider(names_from = year, values_from = oda, values_fill = 0) %>%
    rename(Donor = donor_name, Region = region_label)
  for (yr in required_years) { if (!yr %in% names(donor_region_year_non_cf)) donor_region_year_non_cf[[yr]] <- 0 }
  donor_region_year_non_cf <- donor_region_year_non_cf %>% arrange(Donor, Region) %>% select(Donor, Region, all_of(required_years))

  donor_income_group_year_non_cf <- non_cf_data %>%
    mutate(income_group_label = coalesce(income_group, "Regional and unspecified"), year = as.character(year)) %>%
    group_by(donor_name, income_group_label, year) %>%
    summarise(oda = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    pivot_wider(names_from = year, values_from = oda, values_fill = 0) %>%
    rename(Donor = donor_name, `Income Group` = income_group_label)
  for (yr in required_years) { if (!yr %in% names(donor_income_group_year_non_cf)) donor_income_group_year_non_cf[[yr]] <- 0 }
  donor_income_group_year_non_cf <- donor_income_group_year_non_cf %>% arrange(Donor, `Income Group`) %>% select(Donor, `Income Group`, all_of(required_years))

  rm(non_cf_data)
  message("Non-CF sector/region/income group breakdowns built.")
}

# ----------------------------------------------------------------------------------
# --- SECTOR PIVOT FUNCTION ---
# ----------------------------------------------------------------------------------

# Reusable function: builds the 4-row-per-donor sector pivot table
build_sector_pivot <- function(data, sector_flag_col, sector_label) {
  sector_data <- data %>% filter(!!sym(sector_flag_col))
  child_sector_data <- sector_data %>% filter(c_summary_australia_sdg_adjusted == "Y")

  # Row 1: Child focused ODA to sector by donor × year
  child_sector_by_year <- child_sector_data %>%
    group_by(donor_name, year) %>%
    summarise(value = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    mutate(year = as.character(year)) %>%
    pivot_wider(names_from = year, values_from = value, values_fill = 0) %>%
    mutate(Type = paste0("Child focused ODA to ", sector_label)) %>%
    rename(Donor = donor_name)

  # Row 2: Total ODA to sector by donor × year
  total_sector_by_year <- sector_data %>%
    group_by(donor_name, year) %>%
    summarise(value = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    mutate(year = as.character(year)) %>%
    pivot_wider(names_from = year, values_from = value, values_fill = 0) %>%
    mutate(Type = paste0("Total ODA to ", sector_label)) %>%
    rename(Donor = donor_name)

  # Always use fixed 2014-2024 year columns
  all_years <- as.character(2014:2024)
  for (yr in all_years) {
    if (!yr %in% names(child_sector_by_year)) child_sector_by_year[[yr]] <- 0
    if (!yr %in% names(total_sector_by_year)) total_sector_by_year[[yr]] <- 0
  }

  # Row 3: Child focused as % of total ODA to sector
  pct_of_sector <- child_sector_by_year %>%
    select(Donor, all_of(all_years)) %>%
    left_join(total_sector_by_year %>% select(Donor, all_of(all_years)),
              by = "Donor", suffix = c("_child", "_total"))
  pct_rows <- tibble(Donor = pct_of_sector$Donor,
                     Type = paste0("Child focused ODA as % of total ODA to ", sector_label))
  for (yr in all_years) {
    child_col <- paste0(yr, "_child")
    total_col <- paste0(yr, "_total")
    pct_rows[[yr]] <- if_else(
      pct_of_sector[[total_col]] > 0,
      round(100 * pct_of_sector[[child_col]] / pct_of_sector[[total_col]], 2),
      NA_real_
    )
  }

  # Row 4: Donor's child focused as % of all-donor child focused to sector
  group_child_totals <- child_sector_data %>%
    group_by(year) %>%
    summarise(group_total = sum(usd_disbursement_defl, na.rm = TRUE), .groups = "drop") %>%
    mutate(year = as.character(year))
  group_totals_vec <- setNames(group_child_totals$group_total, group_child_totals$year)

  share_rows <- tibble(Donor = child_sector_by_year$Donor,
                       Type = paste0("Child focused ODA as % of all-donor child focused ODA to ", sector_label))
  for (yr in all_years) {
    gt <- if (!is.null(group_totals_vec[[yr]]) && !is.na(group_totals_vec[[yr]])) group_totals_vec[[yr]] else 0
    share_rows[[yr]] <- if (isTRUE(gt > 0)) {
      round(100 * child_sector_by_year[[yr]] / gt, 2)
    } else {
      rep(NA_real_, nrow(child_sector_by_year))
    }
  }

  # Combine: interleave donors with 4 rows each
  combined <- bind_rows(
    child_sector_by_year %>% select(Donor, Type, all_of(all_years)),
    total_sector_by_year %>% select(Donor, Type, all_of(all_years)),
    pct_rows %>% select(Donor, Type, all_of(all_years)),
    share_rows %>% select(Donor, Type, all_of(all_years))
  ) %>%
    arrange(Donor, factor(Type, levels = c(
      paste0("Child focused ODA to ", sector_label),
      paste0("Total ODA to ", sector_label),
      paste0("Child focused ODA as % of total ODA to ", sector_label),
      paste0("Child focused ODA as % of all-donor child focused ODA to ", sector_label)
    )))

  return(combined)
}

message("Sector pivot function ready.")

# Define output paths
base_path <- "./output"
output_filename_xlsx <- "all donors summary.xlsx"
output_workbook_path <- file.path(base_path, output_filename_xlsx)

output_dir <- dirname(output_workbook_path)
if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

# Save the requested Excel workbook with an explanatory tab and summary tabs
wb <- createWorkbook()

tab_guide <- tibble(
  Tab = c(
    "About this workbook",
    "Total bilateral ODA",
    "Bilateral child-focused ODA",
    "CF % of bilateral ODA",
    "CF % of total CF",
    "ODA % of total ODA",
    "Total bilateral ODA (ex-IDRC)",
    "Child-focused ODA (ex-IDRC)",
    "CF % of bilateral ODA (ex-IDRC)",
    "CF % of total CF (ex-IDRC)",
    "ODA % of total ODA (ex-IDRC)",
    "CF by Sector",
    "CF by Region",
    "CF by Income Group",
    "Health",
    "Humanitarian",
    "Basic Nutrition",
    "Nutrition (12240 + marker)",
    "Water & Sanitation",
    "Social Protection",
    "Education"
  ),
  Description = c(
    "Explains what each sheet in this workbook contains.",
    "Total bilateral ODA (USD) by donor and year (2014-2024), DAC and EU donors.",
    "Bilateral child-focused ODA (USD) by donor and year (2014-2024), DAC and EU donors.",
    "Each donor's child-focused ODA as a percentage of their own total bilateral ODA, by year (2014-2024).",
    "Each donor's child-focused ODA as a percentage of the DAC+EU group total child-focused ODA, by year (2014-2024).",
    "Each donor's total bilateral ODA as a percentage of the DAC+EU group total bilateral ODA, by year (2014-2024).",
    "Total bilateral ODA (USD) excluding sector_code prefix 930* (IDRC), by donor and year (2014-2024), DAC and EU donors.",
    "Bilateral child-focused ODA (USD) excluding sector_code prefix 930* (IDRC), by donor and year (2014-2024), DAC and EU donors.",
    "Each donor's child-focused ODA as % of own total bilateral ODA, excluding sector_code prefix 930* (IDRC), by year (2014-2024).",
    "Each donor's child-focused ODA as % of DAC+EU group total child-focused ODA, excluding sector_code prefix 930* (IDRC), by year (2014-2024).",
    "Each donor's total bilateral ODA as % of DAC+EU group total bilateral ODA, excluding sector_code prefix 930* (IDRC), by year (2014-2024).",
    "Child-focused ODA (USD) by donor, broad sector (Aggregate sectors 1 from purpose_ref) and year (2014-2024). Each row is one donor-sector combination.",
    "Child-focused ODA (USD) by donor, recipient region (Region aggregated 1 from Recipients_regions_ref) and year (2014-2024). Each row is one donor-region combination.",
    "Child-focused ODA (USD) by donor, recipient income group (from income_groups.csv via World Bank classification) and year (2014-2024). Each row is one donor-income group combination.",
    "Health sector (DAC and EU donors only): child-focused ODA, total ODA, child % of sector, and donor share of group child-focused ODA.",
    "Humanitarian sector (DAC and EU donors only): child-focused ODA, total ODA, child % of sector, and donor share of group child-focused ODA.",
    "Basic Nutrition (DAC and EU donors only; purpose code 12240 only): child-focused ODA, total ODA, child % of sector, and donor share.",
    "Nutrition (DAC and EU donors only; purpose code 12240 or nutrition marker 1/2): child-focused ODA, total ODA, child % of sector, and donor share.",
    "Water & Sanitation sector (DAC and EU donors only): child-focused ODA, total ODA, child % of sector, and donor share of group child-focused ODA.",
    "Social Protection (DAC and EU donors only; purpose code 16010): child-focused ODA, total ODA, child % of sector, and donor share of group child-focused ODA.",
    "Education sector (DAC and EU donors only): child-focused ODA, total ODA, child % of sector, and donor share of group child-focused ODA."
  )
)

if (include_non_cf_breakdowns) {
  tab_guide <- bind_rows(tab_guide, tibble(
    Tab = c("Non-CF by Sector", "Non-CF by Region", "Non-CF by Income Group"),
    Description = c(
      "Non-child-focused ODA (USD) by donor, broad sector and year (2014-2024). All ODA not classified as child-focused.",
      "Non-child-focused ODA (USD) by donor, recipient region and year (2014-2024). All ODA not classified as child-focused.",
      "Non-child-focused ODA (USD) by donor, recipient income group and year (2014-2024). All ODA not classified as child-focused."
    )
  ))
}

addWorksheet(wb, "About this workbook")
writeData(wb, "About this workbook", tab_guide)
setColWidths(wb, "About this workbook", cols = 1:ncol(tab_guide), widths = "auto")
freezePane(wb, "About this workbook", firstRow = TRUE)

addWorksheet(wb, "Total bilateral ODA")
writeData(wb, "Total bilateral ODA", donor_total_oda)
setColWidths(wb, "Total bilateral ODA", cols = 1:ncol(donor_total_oda), widths = "auto")
freezePane(wb, "Total bilateral ODA", firstRow = TRUE)

addWorksheet(wb, "Bilateral child-focused ODA")
writeData(wb, "Bilateral child-focused ODA", donor_child_focus_oda)
setColWidths(wb, "Bilateral child-focused ODA", cols = 1:ncol(donor_child_focus_oda), widths = "auto")
freezePane(wb, "Bilateral child-focused ODA", firstRow = TRUE)

addWorksheet(wb, "CF % of bilateral ODA")
writeData(wb, "CF % of bilateral ODA", donor_child_focus_pct)
setColWidths(wb, "CF % of bilateral ODA", cols = 1:ncol(donor_child_focus_pct), widths = "auto")
freezePane(wb, "CF % of bilateral ODA", firstRow = TRUE)

addWorksheet(wb, "CF % of total CF")
writeData(wb, "CF % of total CF", donor_cf_share)
setColWidths(wb, "CF % of total CF", cols = 1:ncol(donor_cf_share), widths = "auto")
freezePane(wb, "CF % of total CF", firstRow = TRUE)

addWorksheet(wb, "ODA % of total ODA")
writeData(wb, "ODA % of total ODA", donor_oda_share)
setColWidths(wb, "ODA % of total ODA", cols = 1:ncol(donor_oda_share), widths = "auto")
freezePane(wb, "ODA % of total ODA", firstRow = TRUE)

addWorksheet(wb, "Total bilateral ODA (ex-IDRC)")
writeData(wb, "Total bilateral ODA (ex-IDRC)", donor_total_oda_ex_idrc)
setColWidths(wb, "Total bilateral ODA (ex-IDRC)", cols = 1:ncol(donor_total_oda_ex_idrc), widths = "auto")
freezePane(wb, "Total bilateral ODA (ex-IDRC)", firstRow = TRUE)

addWorksheet(wb, "Child-focused ODA (ex-IDRC)")
writeData(wb, "Child-focused ODA (ex-IDRC)", donor_child_focus_oda_ex_idrc)
setColWidths(wb, "Child-focused ODA (ex-IDRC)", cols = 1:ncol(donor_child_focus_oda_ex_idrc), widths = "auto")
freezePane(wb, "Child-focused ODA (ex-IDRC)", firstRow = TRUE)

addWorksheet(wb, "CF % of bilateral ODA (ex-IDRC)")
writeData(wb, "CF % of bilateral ODA (ex-IDRC)", donor_child_focus_pct_ex_idrc)
setColWidths(wb, "CF % of bilateral ODA (ex-IDRC)", cols = 1:ncol(donor_child_focus_pct_ex_idrc), widths = "auto")
freezePane(wb, "CF % of bilateral ODA (ex-IDRC)", firstRow = TRUE)

addWorksheet(wb, "CF % of total CF (ex-IDRC)")
writeData(wb, "CF % of total CF (ex-IDRC)", donor_cf_share_ex_idrc)
setColWidths(wb, "CF % of total CF (ex-IDRC)", cols = 1:ncol(donor_cf_share_ex_idrc), widths = "auto")
freezePane(wb, "CF % of total CF (ex-IDRC)", firstRow = TRUE)

addWorksheet(wb, "ODA % of total ODA (ex-IDRC)")
writeData(wb, "ODA % of total ODA (ex-IDRC)", donor_oda_share_ex_idrc)
setColWidths(wb, "ODA % of total ODA (ex-IDRC)", cols = 1:ncol(donor_oda_share_ex_idrc), widths = "auto")
freezePane(wb, "ODA % of total ODA (ex-IDRC)", firstRow = TRUE)

addWorksheet(wb, "CF by Sector")
writeData(wb, "CF by Sector", donor_sector_year)
setColWidths(wb, "CF by Sector", cols = 1:ncol(donor_sector_year), widths = "auto")
freezePane(wb, "CF by Sector", firstRow = TRUE)

addWorksheet(wb, "CF by Region")
writeData(wb, "CF by Region", donor_region_year)
setColWidths(wb, "CF by Region", cols = 1:ncol(donor_region_year), widths = "auto")
freezePane(wb, "CF by Region", firstRow = TRUE)

addWorksheet(wb, "CF by Income Group")
writeData(wb, "CF by Income Group", donor_income_group_year)
setColWidths(wb, "CF by Income Group", cols = 1:ncol(donor_income_group_year), widths = "auto")
freezePane(wb, "CF by Income Group", firstRow = TRUE)

if (include_non_cf_breakdowns) {
  addWorksheet(wb, "Non-CF by Sector")
  writeData(wb, "Non-CF by Sector", donor_sector_year_non_cf)
  setColWidths(wb, "Non-CF by Sector", cols = 1:ncol(donor_sector_year_non_cf), widths = "auto")
  freezePane(wb, "Non-CF by Sector", firstRow = TRUE)

  addWorksheet(wb, "Non-CF by Region")
  writeData(wb, "Non-CF by Region", donor_region_year_non_cf)
  setColWidths(wb, "Non-CF by Region", cols = 1:ncol(donor_region_year_non_cf), widths = "auto")
  freezePane(wb, "Non-CF by Region", firstRow = TRUE)

  addWorksheet(wb, "Non-CF by Income Group")
  writeData(wb, "Non-CF by Income Group", donor_income_group_year_non_cf)
  setColWidths(wb, "Non-CF by Income Group", cols = 1:ncol(donor_income_group_year_non_cf), widths = "auto")
  freezePane(wb, "Non-CF by Income Group", firstRow = TRUE)
}

# ----------------------------------------------------------------------------------
# --- SECTOR TABS ---
# ----------------------------------------------------------------------------------

sector_configs <- list(
  list(flag = "is_health",             label = "Health",              tab = "Health"),
  list(flag = "is_humanitarian",       label = "Humanitarian",        tab = "Humanitarian"),
  list(flag = "is_basic_nutrition",    label = "Basic Nutrition",     tab = "Basic Nutrition"),
  list(flag = "is_nutrition",          label = "Nutrition",           tab = "Nutrition (12240 + marker)"),
  list(flag = "is_watsan",             label = "Water & Sanitation",  tab = "Water & Sanitation"),
  list(flag = "is_social_protection",  label = "Social Protection",   tab = "Social Protection"),
  list(flag = "is_education",          label = "Education",           tab = "Education")
)

for (sc in sector_configs) {
  message("Building sector tab: ", sc$tab)
  sector_pivot <- build_sector_pivot(crs_data_original_names, sc$flag, sc$label)

  note_text <- paste0("This tab contains child-focused and total ODA breakdowns for the ", sc$label, " sector, by donor and year, for DAC and EU donors only.")
  note_row <- tibble(Donor = note_text)

  addWorksheet(wb, sc$tab)
  writeData(wb, sc$tab, note_row, startRow = 1, colNames = FALSE)
  writeData(wb, sc$tab, sector_pivot, startRow = 3)
  setColWidths(wb, sc$tab, cols = 1:ncol(sector_pivot), widths = "auto")
  freezePane(wb, sc$tab, firstRow = FALSE, firstActiveRow = 4)
}

message("All sector tabs added.")

saveWorkbook(wb, output_workbook_path, overwrite = TRUE)

message("Excel workbook saved to: ", output_workbook_path, " (", nrow(tab_guide), " tabs)")


# ----------------------------------------------------------------------------------
# --- CLEANUP ---
# ----------------------------------------------------------------------------------

rm(crs_data_original_names)
gc()

message("Memory cleanup complete. Environment cleared.")
