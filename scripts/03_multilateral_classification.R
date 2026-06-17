# UNICEF Multilateral CRS Child-Focus Script (27-02-2026)
# Loads CRS parquet data, applies child-focus classification, and exports aggregated multilateral metrics.

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
ensure_package("stringr") # For string manipulation
ensure_package("stringi") # For advanced string manipulation, especially accent handling
ensure_package("arrow") # For reading Parquet files
ensure_package("tibble") # For tribble

# Set locale to UTF-8 for special character handling
tryCatch(Sys.setlocale("LC_ALL", "en_US.UTF-8"), error = function(e) message("Could not set locale to en_US.UTF-8."))


# --- User-configurable settings ---
# Set this to TRUE to filter the final output to only include rows where IsODA is "ODA".
# Set this to FALSE to save the entire processed dataset without this filter.
filter_by_oda <- TRUE

# Set this to TRUE to filter the final output to only include rows where c_summary is "Y".
# Set this to FALSE to save the entire processed dataset without this filter.
# NOTE: The final aggregation step now summarizes Y/non-Y data, so setting this to TRUE
# will cause the "non-Y" metrics to be zeroed out in the final output.
filter_by_c_summary <- FALSE

# Set this to TRUE to filter the final output to only include rows where year >= 2014.
# Set this to FALSE to save the entire processed dataset without this filter.
filter_by_year_ge_2014 <- TRUE

# Enter the name of a specific donor to filter on (e.g., "United States").
# Leave this as an an empty string ("") to process all donors.
donor_filter_name <- ""

# Set this to TRUE to extract and display which specific keywords were matched for each flagged row.
# Set this to FALSE to skip keyword extraction (column will not be created in output).
extract_matched_keywords <- FALSE

# --- List of specific Multilateral Donor Codes to include for early filtering ---
# Only rows matching one of these multilateral codes will be kept.
multilateral_donor_code_list <- c(
  1012, 913, 914, 953, 921, 980, 915, 1053, 1024, 981, 906, 1025, 910, 1020, 1055, 1011,
  926, 1013, 1047, 1017, 1015, 918, 990, 932, 1311, 1018, 811, 1312, 1313, 997, 982, 1016,
  1019, 988, 958, 1058, 956, 909, 944, 901, 1052, 1049, 905, 903, 1037, 940, 907, 976, 979,
  1048, 812, 902, 104, 1045, 952, 951, 978, 983, 1014, 954, 992, 1039, 1057, 1403, 1038,
  1040, 923, 1046, 971, 959, 948, 807, 974, 967, 963, 962, 1406, 964, 960, 966, 1050, 928,
  1054, 1023, 1404, 1401, 1022, 1026, 1036, 1041, 1042, 1043, 1044, 1051, 1056
)

# ----------------------------------------------------------------------------------
# --- Core Data Loading Logic: Load Parquet File ---
# ----------------------------------------------------------------------------------

# --- Your Input File Path (Parquet) ---
# The Parquet file is highly efficient and preserves column types. It is expected to use
# the snake_case column names like 'year', 'donor_code', 'usd_disbursement_defl', etc.
parquet_file_path <- './input/CRS.parquet'

if (!file.exists(parquet_file_path)) {
  stop(paste0("Parquet file not found: '", parquet_file_path, "'. Please check the path."))
}

# Load the Parquet file using the 'arrow' library
crs_data_original_names <- arrow::read_parquet(parquet_file_path)


# ----------------------------------------------------------------------------------
# --- BEGIN DATA PROCESSING LOGIC (Using snake_case Names) ---
# ----------------------------------------------------------------------------------

# --- EARLY FILTERING TO SAVE MEMORY ---

# 1. Early filtering by donor_name (formerly DonorName)
if (!is.null(donor_filter_name) && donor_filter_name != "") {
  if ("donor_name" %in% names(crs_data_original_names)) {
    # Using an accent-insensitive filter
    crs_data_original_names <- crs_data_original_names %>%
      filter(stringi::stri_trans_general(donor_name, "latin-ascii") == stringi::stri_trans_general(donor_filter_name, "latin-ascii"))
  } else {
    warning("      - 'donor_name' column not found. Donor name filtering was NOT performed.")
  }
}

# 2. Early filtering by Multilateral Donor Code (formerly DonorCode)
if (length(multilateral_donor_code_list) > 0) {
  if ("donor_code" %in% names(crs_data_original_names)) {
    # Filter keeps only rows where donor_code is in the provided multilateral list
    # Convert donor_code to numeric temporarily for accurate matching against the list
    crs_data_original_names <- crs_data_original_names %>%
      mutate(donor_code_num = as.numeric(donor_code)) %>%
      filter(donor_code_num %in% multilateral_donor_code_list) %>%
      select(-donor_code_num) # Remove the temporary column
  } else {
    warning("      - 'donor_code' column not found. Multilateral donor code list filtering was NOT performed.")
  }
}

# --- Early filtering for ODA and Year to save memory ---
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


# --- Add new column by concatenating text fields (Using snake_case Names) ---
description_cols_original <- c("short_description", "project_title", "long_description")

if (all(description_cols_original %in% names(crs_data_original_names))) {
  crs_data_original_names <- crs_data_original_names %>%
    mutate(Combined_Description = paste(
      coalesce(.[["short_description"]], ""),
      coalesce(.[["project_title"]], ""),
      coalesce(.[["long_description"]], ""),
      sep = " "
    )) %>%
    mutate(Combined_Description = str_replace_all(Combined_Description, "[[:punct:]]", " ")) %>%
    mutate(Combined_Description = trimws(Combined_Description)) %>%
    mutate(Combined_Description = str_replace_all(Combined_Description, "\\s+", " "))
} else {
  missing_desc_cols <- description_cols_original[!(description_cols_original %in% names(crs_data_original_names))]
  warning("      - The following description columns were NOT found: ", paste(missing_desc_cols, collapse = ", "), ". 'Combined_Description' column was NOT created.")
}

# ----------------------------------------------------------------------------------
# --- ADDING NEW CLASSIFICATION COLUMNS (Using snake_case Names for Input) ---

# Define code lists
# Note: The following purpose codes are excluded because we are following an explicit
# targeting framework rather than a welfare incidence approach:
# 14020, 14021, 14022, 14030, 14031, 14032, 16010.
# Note: 11232 is excluded due to its label 'Primary education equivalent for adults'.
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

# Note: The following SDGs are excluded because they may include funding focused on
# adults and/or tertiary levels: 4, 4.3, 4.4, 4.5, 4.6, 4.7, 4.b, 4.c, 5.1, 5.2, 16.9.
sdg_focus_targets <- c("3.1", "3.2", "3.7", "4.1", "4.2", "4.a", "5.3", "8.7", "16.2")
sdg_focus_targets <- tolower(trimws(sdg_focus_targets))

# --- Redefining keywords ---
# Note: Some variants may look redundant (e.g., singular/plural forms) under current
# substring matching, but are intentionally kept for future-proofing if stricter
# matching (such as more word-boundary rules) is introduced later.

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

# Note: Included for recall, but may be reconsidered for precision because they can
# capture broader non-child contexts: youth, youths, youthful, young person, youngest.

# Note: If a donor-specific language rule is introduced, the following donors can
# report in French: France, Belgium, Luxembourg, Canada, Germany, EU Institutions,
# Switzerland, African Development Bank, African Development Fund, Monaco, IFAD,
# Netherlands, Food and Agriculture Organization, WTO - International Trade Centre,
# Central Emergency Response Fund, UNAIDS, UN Peacebuilding Fund,
# International Labour Organisation, UNDP.

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

# Note: Included for recall, but may be reconsidered for precision because they can
# capture broader non-child contexts: jeunesse, jeune, jeunes, plus[ -]?jeune.

# Note: If a donor-specific language rule is introduced, the following donors can
# report in Spanish: Spain, Central American Bank for Economic Integration,
# Inter-American Development Bank, Development Bank of Latin America,
# UN Peacebuilding Fund, EU Institutions, UNDP.

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

# Note: Included for recall, but may be reconsidered for precision because they can
# capture broader non-child contexts: juventud, joven, jovenes, más joven.

# Note: Dutch keyword 'kind' is intentionally excluded due to high false-positive risk.
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

# Note: Included for recall, but may be reconsidered for precision because they can
# capture broader non-child contexts: jeugd, jongere, jongeren, jeugdig,
# jonge mensen.

# Note: German keywords 'Kind' and 'Kita' are intentionally excluded due to high false-positive risk.
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

# Note: Included for recall, but may be reconsidered for precision because they can
# capture broader non-child contexts: Jugendlicher, Jugendliche, Jugend, jugendlich,
# die Jugend, junge Menschen.

# Build language regex patterns.
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

# Donor-code gates for donor-specific language keywords.
donor_codes_french <- c(
  "4",    # France
  "2",    # Belgium
  "22",   # Luxembourg
  "301",  # Canada
  "5",    # Germany
  "918",  # EU Institutions
  "11",   # Switzerland
  "913",  # African Development Bank
  "914",  # African Development Fund
  "26",   # Monaco
  "988",  # IFAD
  "7",    # Netherlands
  "932",  # Food and Agriculture Organisation
  "1401", # WTO - International Trade Centre
  "1020", # Central Emergency Response Fund
  "971",  # UNAIDS
  "923",  # UN Peacebuilding Fund
  "940",  # International Labour Organisation
  "959"   # UNDP
)
donor_code_netherlands <- "7" # Netherlands
donor_code_germany <- "5" # Germany
donor_codes_spanish <- c(
  "50",   # Spain
  "910",  # Central American Bank for Economic Integration
  "909",  # Inter-American Development Bank
  "1015", # Development Bank of Latin America
  "923",  # UN Peacebuilding Fund
  "918",  # EU Institutions
  "959"   # UNDP
)

# Full pattern retained for matched-keyword extraction output.
# Keep this aligned with c_keyword language logic so extraction is consistent.
all_keywords <- c(core_keywords, french_keywords, spanish_keywords, dutch_keywords, german_keywords)
all_keywords_normalized <- stringi::stri_trans_general(all_keywords, "latin-ascii")
keyword_pattern_all <- paste(all_keywords_normalized, collapse = "|")

# Additional WATSAN keyword rule (qualitative-research based, accuracy-oriented):
# For purpose codes 14020/14021/14022/14030/14031/14032, classify as keyword if
# school-equivalent terms are present in EN/FR/ES descriptions.
watsan_additional_purpose_codes <- c("14020", "14021", "14022", "14030", "14031", "14032")
watsan_school_pattern <- "\\bschools?\\b|\\becoles?\\b|\\bescuelas?\\b"


# Create the new columns and populate them based on your rules
crs_data_original_names <- crs_data_original_names %>%
  mutate(
    c_purpose = case_when(
      `purpose_code` %in% code_lists$purpose ~ "Y",
      TRUE ~ ""
    ),
    c_channel = case_when(
      `channel_code` %in% code_lists$channel ~ "Y",
      stringi::stri_detect_regex(stringi::stri_trans_general(coalesce(`channel_reported_name`, ""), "latin-ascii"),
                                   paste0("(?i)(", paste(gsub(" ", "[ -]?", code_lists$channel_rep_name_keywords), collapse = "|"), ")")) ~ "Y",
      TRUE ~ ""
    ),
    c_donor_type = case_when(
      as.character(`donor_code`) %in% code_lists$donor_type ~ "Y",
      TRUE ~ ""
    ),
    c_marker = case_when(
      `rmnch` %in% c("1", "2") ~ "Y",
      TRUE ~ ""
    ),
    c_keyword = case_when(
      (
        stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                   keyword_pattern_core,
                                   case_insensitive = TRUE) |
          (
            coalesce(as.character(donor_code), "") %in% donor_codes_french &
              stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                         keyword_pattern_french,
                                         case_insensitive = TRUE)
          ) |
          (
            coalesce(as.character(donor_code), "") == donor_code_netherlands &
              stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                         keyword_pattern_dutch,
                                         case_insensitive = TRUE)
          ) |
          (
            coalesce(as.character(donor_code), "") == donor_code_germany &
              stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                         keyword_pattern_german,
                                         case_insensitive = TRUE)
          ) |
          (
            coalesce(as.character(donor_code), "") %in% donor_codes_spanish &
              stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                         keyword_pattern_spanish,
                                         case_insensitive = TRUE)
          )
      ) ~ "Y",
      as.character(`purpose_code`) %in% watsan_additional_purpose_codes &
        stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                   watsan_school_pattern,
                                   case_insensitive = TRUE) ~ "Y (watsan additional)",
      TRUE ~ ""
    )
  )

# Extract matched keywords for rows flagged as c_keyword (if enabled)
if (extract_matched_keywords) {
  # Add temporary row ID for joining
  crs_data_original_names <- crs_data_original_names %>%
    mutate(temp_row_id = row_number())
  
  # Extract keywords only for flagged rows (much faster)
  flagged_keywords <- crs_data_original_names %>%
    filter(c_keyword %in% c("Y", "Y (watsan additional)")) %>%
    mutate(
      keywords_matched = sapply(
        seq_len(n()),
        function(i) {
          description_text <- coalesce(Combined_Description[i], "")
          if (c_keyword[i] == "Y") {
            # For keyword matches, extract from full keyword pattern
            matches <- stringi::stri_extract_all(
              stringi::stri_trans_general(description_text, "latin-ascii"),
              regex = keyword_pattern_all,
              case_insensitive = TRUE
            )[[1]]
          } else {
            # For watsan additional, extract from watsan_school_pattern
            matches <- stringi::stri_extract_all(
              stringi::stri_trans_general(description_text, "latin-ascii"),
              regex = watsan_school_pattern,
              case_insensitive = TRUE
            )[[1]]
          }
          matches <- matches[!is.na(matches)]
          if (length(matches) == 0) ""
          else paste(tolower(matches), collapse = ", ")
        }
      )
    ) %>%
    select(temp_row_id, keywords_matched)
  
  # Join back to main dataset
  crs_data_original_names <- crs_data_original_names %>%
    left_join(flagged_keywords, by = "temp_row_id") %>%
    mutate(keywords_matched = ifelse(is.na(keywords_matched), "", keywords_matched)) %>%
    select(-temp_row_id)
}

# Standardize keyword flag labels in final output.
crs_data_original_names <- crs_data_original_names %>%
  mutate(c_keyword = if_else(c_keyword == "Y (watsan additional)", "Y", c_keyword))

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
  mutate(
    c_trigger_source_count =
      as.integer(c_purpose == "Y") +
      as.integer(c_channel == "Y") +
      as.integer(c_donor_type == "Y") +
      as.integer(c_marker == "Y") +
      as.integer(c_keyword == "Y") +
      as.integer(c_sdg == "Y"),
    c_trigger_source = case_when(
      c_trigger_source_count > 1 ~ "multiple",
      c_purpose == "Y" ~ "c_purpose",
      c_channel == "Y" ~ "c_channel",
      c_donor_type == "Y" ~ "c_donor_type",
      c_marker == "Y" ~ "c_marker",
      c_keyword == "Y" ~ "c_keyword",
      c_sdg == "Y" ~ "c_sdg",
      TRUE ~ ""
    )
  ) %>%
  select(-c_trigger_source_count)


# --- FINAL STEP: Apply final filters ---
# Use a final variable name as requested
c_crs_data <- crs_data_original_names

# Check and apply the c_summary filter
if (filter_by_c_summary) {
  if ("c_summary" %in% names(c_crs_data)) {
    c_crs_data <- c_crs_data %>%
      filter(c_summary == "Y")
  } else {
    warning("      - 'c_summary' column not found. c_summary filtering was not performed.")
  }
}

# --- MODIFIED STEP: AGGREGATE TO WIDE FORMAT AND SAVE DATA ---
# The aggregation is now done based only on time and donor identity
aggregation_cols <- c("year", "donor_code", "donor_name")
metric_col <- "usd_disbursement_defl" # This holds the name of the column we are summing

if (all(c(aggregation_cols, metric_col) %in% names(c_crs_data))) {
  # 1. First, create the annual aggregated dataset
  c_crs_aggregated_data <- c_crs_data %>%
    group_by(year, donor_code, donor_name) %>%
    summarise(
      usd_defl_child_focus = sum(usd_disbursement_defl[c_summary == "Y"], na.rm = TRUE),
      usd_defl_other = sum(usd_disbursement_defl[c_summary != "Y"], na.rm = TRUE),
      usd_defl_total = sum(usd_disbursement_defl, na.rm = TRUE),
      .groups = 'drop'
    ) %>%
    mutate(
      child_focus_percent = ifelse(
        usd_defl_total == 0,
        0,
        usd_defl_child_focus / usd_defl_total
      )
    )
  
  # 2. NEW: Calculate the weighted 5-year average (2020-2024) per donor
  c_crs_5year_avg <- c_crs_aggregated_data %>%
    filter(year >= 2020 & year <= 2024) %>%
    group_by(donor_code, donor_name) %>%
    summarise(
      sum_child_focus_5yr = sum(usd_defl_child_focus, na.rm = TRUE),
      sum_total_5yr = sum(usd_defl_total, na.rm = TRUE),
      .groups = 'drop'
    ) %>%
    mutate(
      child_focus_percent_5year = ifelse(
        sum_total_5yr == 0,
        0,
        sum_child_focus_5yr / sum_total_5yr
      )
    ) %>%
    select(donor_code, donor_name, child_focus_percent_5year)
  
  # 3. Join the 5-year average back to the main aggregated data
  c_crs_aggregated_data <- c_crs_aggregated_data %>%
    left_join(c_crs_5year_avg, by = c("donor_code", "donor_name")) %>%
    # Fill NAs with 0 if a donor had no data in the 2020-2024 period
    mutate(child_focus_percent_5year = coalesce(child_focus_percent_5year, 0))
  
  # Define output path and filename for the aggregated CSV
  base_path <- "./output"
  aggregated_base_filename <- "c_crs_multi_aggregated_parquet"
  
  if (!is.null(donor_filter_name) && donor_filter_name != "") {
    clean_donor_name <- str_replace_all(donor_filter_name, " ", "_")
    aggregated_output_filename <- paste0(aggregated_base_filename, "_", clean_donor_name, "_wide.csv")
  } else {
    aggregated_output_filename <- paste0(aggregated_base_filename, "_wide.csv")
  }
  
  output_aggregated_csv_path <- file.path(base_path, aggregated_output_filename)
  
  output_dir <- dirname(output_aggregated_csv_path)
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }
  
  # Saving the final combined dataset
  write_csv(c_crs_aggregated_data, output_aggregated_csv_path, na = "")
  
  message("Data saved to: ", output_aggregated_csv_path, " (", nrow(c_crs_aggregated_data), " rows, ", ncol(c_crs_aggregated_data), " columns)")
  
} else {
  missing_cols <- c(aggregation_cols, metric_col)[!(c(aggregation_cols, metric_col) %in% names(c_crs_data))]
  warning("Skipping aggregation: One or more required columns are missing from the final dataset: ", paste(missing_cols, collapse = ", "), ".")
}

# ----------------------------------------------------------------------------------
# --- CLEANUP: Free memory after processing ---
# ----------------------------------------------------------------------------------

# Remove large data objects to free memory
rm(crs_data_original_names, c_crs_data, c_crs_aggregated_data, c_crs_5year_avg)

# Force garbage collection to release memory back to the system
gc()

message("Memory cleanup complete. Environment cleared.")