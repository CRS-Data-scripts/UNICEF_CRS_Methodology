# UNICEF Donor CRS Child-Focus Script (27-02-2026)
# GitHub Version - Portable Relative Paths
# Loads CRS parquet data, applies child-focus classification flags, and exports donor-level output.

# ----- SETUP INSTRUCTIONS -----
# Before running this script, please:
# 1. Download the CRS Parquet file from https://data-explorer.oecd.org/
#    - Search for: "CRS: Creditor Reporting System (flows)"
#    - Download the Parquet version
#    - Save it as: input/CRS.parquet
# 2. Ensure the input/reference_files/ folder contains all CSV reference files
# 3. See SETUP.md for detailed instructions
# --------------------------------

# Helper function to ensure packages are installed and loaded
ensure_package <- function(package_name) {
  if (!requireNamespace(package_name, quietly = TRUE)) {
    install.packages(package_name, dependencies = TRUE)
  }
  library(package_name, character.only = TRUE)
}

# Load necessary libraries
ensure_package("readr")
ensure_package("dplyr")
ensure_package("stringr") # For string manipulation
ensure_package("stringi") # For advanced string manipulation, especially accent handling
ensure_package("arrow") # For reading Parquet files (MANDATORY for this version)

# Set locale to UTF-8 for special character handling
tryCatch(Sys.setlocale("LC_ALL", "en_US.UTF-8"), error = function(e) message("Could not set locale to en_US.UTF-8."))

# --- User-configurable settings ---
# Set this to TRUE to filter the final output to only include rows where IsODA is "ODA".
filter_by_oda <- TRUE

# Set this to TRUE to filter the final output to only include rows where c_summary is "Y".
filter_by_c_summary <- FALSE

# Set this to TRUE to filter the final output to only include rows where Year >= 2014.
filter_by_year_ge_2014 <- TRUE

# Optional: filter to a single specific year (e.g., 2022).
specific_year_filter <- NA

# Enter the name of a specific donor to filter on (e.g., "United States").
# Leave as an empty string ("") to process all donors.
donor_filter_name <- "Germany"

# Enter one or more donor names for which the SDG-only exclusion rule should apply.
donors_apply_sdg_exclusion_rule <- c("Australia")

# Set this to TRUE to extract matched keywords for each row.
extract_matched_keywords <- FALSE

# Set this to TRUE to join reference file lookups to the output.
include_reference_files <- FALSE

# ----------------------------------------------------------------------------------
# --- Core Data Loading Logic: Load Single Parquet File ---
# ----------------------------------------------------------------------------------

# Input parquet file path (relative to script location)
parquet_file_path <- "./input/CRS.parquet"

# Stop early if the file path is wrong
if (!file.exists(parquet_file_path)) {
  stop("Parquet file not found at: '", parquet_file_path, "'\n",
       "Please download the CRS Parquet file from https://data-explorer.oecd.org/ and save it to input/CRS.parquet\n",
       "See SETUP.md for detailed instructions.")
}

# Load parquet data
crs_data_original_names <- arrow::read_parquet(parquet_file_path)

# ----------------------------------------------------------------------------------
# --- BEGIN DATA PROCESSING LOGIC (Using Original Names) ---
# ----------------------------------------------------------------------------------

# --- EARLY FILTERING ---

# 1. Early filtering by DonorName
if (!is.null(donor_filter_name) && donor_filter_name != "") {
  if ("donor_name" %in% names(crs_data_original_names)) {
    crs_data_original_names <- crs_data_original_names %>%
      filter(stringi::stri_trans_general(donor_name, "latin-ascii") == stringi::stri_trans_general(donor_filter_name, "latin-ascii"))
  } else {
    warning("'donor_name' column not found. Donor name filtering was NOT performed.")
  }
}

# --- Early filtering for ODA and Year ---
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

# Optional exact year filter
if (!is.na(specific_year_filter) && "year" %in% names(crs_data_original_names)) {
  crs_data_original_names <- crs_data_original_names %>%
    mutate(year = as.numeric(year)) %>%
    filter(year == as.numeric(specific_year_filter))
}

# --- Add new column by concatenating text fields ---
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
  warning("The following description columns were NOT found: ", paste(missing_desc_cols, collapse = ", "))
}

# ----------------------------------------------------------------------------------
# --- ADDING NEW CLASSIFICATION COLUMNS ---
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
    "Save the Children", "Global Partnership for Education",
    "Forum for African Women Educationalists",
    "International Finance Facility for Education", "UNICEF",
    "United Nations Children's Fund"
  ),
  donor_type = c("963")  # UNICEF
)

sdg_focus_targets <- c("3.1", "3.2", "3.7", "4.1", "4.2", "4.a", "5.3", "8.7", "16.2")
sdg_focus_targets <- tolower(trimws(sdg_focus_targets))

# Keyword lists (English + multilingual)
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

# Build normalized keyword patterns
core_keywords_normalized <- stringi::stri_trans_general(english_keywords, "latin-ascii")
french_keywords_normalized <- stringi::stri_trans_general(french_keywords, "latin-ascii")
spanish_keywords_normalized <- stringi::stri_trans_general(spanish_keywords, "latin-ascii")
dutch_keywords_normalized <- stringi::stri_trans_general(dutch_keywords, "latin-ascii")
german_keywords_normalized <- stringi::stri_trans_general(german_keywords, "latin-ascii")

keyword_pattern_core <- paste(core_keywords_normalized, collapse = "|")
keyword_pattern_french <- paste(french_keywords_normalized, collapse = "|")
keyword_pattern_spanish <- paste(spanish_keywords_normalized, collapse = "|")
keyword_pattern_dutch <- paste(dutch_keywords_normalized, collapse = "|")
keyword_pattern_german <- paste(german_keywords_normalized, collapse = "|")

# Donor-code gates for language keywords
donor_codes_french <- c("4", "2", "22", "301", "5", "918", "11", "913", "914", "26", "988", "7", "932", "1401", "1020", "971", "923", "940", "959")
donor_code_netherlands <- "7"
donor_code_germany <- "5"
donor_codes_spanish <- c("50", "910", "909", "1015", "923", "918", "959")

# Full keyword pattern for extraction
all_keywords <- c(english_keywords, french_keywords, spanish_keywords, dutch_keywords, german_keywords)
all_keywords_normalized <- stringi::stri_trans_general(all_keywords, "latin-ascii")
keyword_pattern_all <- paste(all_keywords_normalized, collapse = "|")

# WATSAN additional keywords
watsan_additional_purpose_codes <- c("14020", "14021", "14022", "14030", "14031", "14032")
watsan_school_pattern <- "\\bschools?\\b|\\becoles?\\b|\\bescuelas?\\b"

# Create classification columns
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
                                   keyword_pattern_core, case_insensitive = TRUE) |
          (coalesce(as.character(donor_code), "") %in% donor_codes_french &
            stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                       keyword_pattern_french, case_insensitive = TRUE)) |
          (coalesce(as.character(donor_code), "") == donor_code_netherlands &
            stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                       keyword_pattern_dutch, case_insensitive = TRUE)) |
          (coalesce(as.character(donor_code), "") == donor_code_germany &
            stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                       keyword_pattern_german, case_insensitive = TRUE)) |
          (coalesce(as.character(donor_code), "") %in% donor_codes_spanish &
            stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                       keyword_pattern_spanish, case_insensitive = TRUE))
      ) ~ "Y",
      as.character(`purpose_code`) %in% watsan_additional_purpose_codes &
        stringi::stri_detect_regex(stringi::stri_trans_general(Combined_Description, "latin-ascii"),
                                   watsan_school_pattern, case_insensitive = TRUE) ~ "Y (watsan additional)",
      TRUE ~ ""
    )
  )

# Extract matched keywords (if enabled)
if (extract_matched_keywords) {
  crs_data_original_names <- crs_data_original_names %>% mutate(temp_row_id = row_number())
  
  flagged_keywords <- crs_data_original_names %>%
    filter(c_keyword %in% c("Y", "Y (watsan additional)")) %>%
    mutate(
      keywords_matched = sapply(seq_len(n()), function(i) {
        description_text <- coalesce(Combined_Description[i], "")
        if (c_keyword[i] == "Y") {
          matches <- stringi::stri_extract_all(
            stringi::stri_trans_general(description_text, "latin-ascii"),
            regex = keyword_pattern_all, case_insensitive = TRUE
          )[[1]]
        } else {
          matches <- stringi::stri_extract_all(
            stringi::stri_trans_general(description_text, "latin-ascii"),
            regex = watsan_school_pattern, case_insensitive = TRUE
          )[[1]]
        }
        matches <- matches[!is.na(matches)]
        if (length(matches) == 0) "" else paste(tolower(matches), collapse = ", ")
      })
    ) %>%
    select(temp_row_id, keywords_matched)
  
  crs_data_original_names <- crs_data_original_names %>%
    left_join(flagged_keywords, by = "temp_row_id") %>%
    mutate(keywords_matched = ifelse(is.na(keywords_matched), "", keywords_matched)) %>%
    select(-temp_row_id)
}

# Standardize keyword flag labels
crs_data_original_names <- crs_data_original_names %>%
  mutate(c_keyword = if_else(c_keyword == "Y (watsan additional)", "Y", c_keyword))

# c_sdg from sd_gfocus
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
    length(donors_apply_sdg_exclusion_rule) > 0 &
      coalesce(donor_name, "") %in% donors_apply_sdg_exclusion_rule &
      c_sdg == "Y" & c_purpose != "Y" & c_channel != "Y" & c_marker != "Y" & c_keyword != "Y" & c_donor_type != "Y" ~ "",
    c_purpose == "Y" | c_channel == "Y" | c_marker == "Y" | c_keyword == "Y" | c_donor_type == "Y" | c_sdg == "Y" ~ "Y",
    TRUE ~ ""
  )) %>%
  mutate(
    c_trigger_source_count = as.integer(c_purpose == "Y") + as.integer(c_channel == "Y") +
      as.integer(c_donor_type == "Y") + as.integer(c_marker == "Y") + as.integer(c_keyword == "Y") +
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

# Final dataset variable
c_crs_data <- crs_data_original_names

# Apply final c_summary filter
if (filter_by_c_summary) {
  if ("c_summary" %in% names(c_crs_data)) {
    c_crs_data <- c_crs_data %>% filter(c_summary == "Y")
  }
}

# ----------------------------------------------------------------------------------
# --- OPTIONAL: Reference file lookups ---
# ----------------------------------------------------------------------------------

if (include_reference_files) {
  message("Loading reference files...")
  ref_base <- "./input/reference_files/"

  # Check that reference folder exists
  if (!dir.exists(ref_base)) {
    warning("Reference files folder not found at: '", ref_base, "'. Skipping reference file lookups.")
    include_reference_files <- FALSE
  } else {
    # Load reference files
    donor_type_ref_data <- read_csv(file.path(ref_base, "donor_type_ref.csv"), show_col_types = FALSE) %>%
      select(donor_code, `Donor type` = donor_type) %>%
      mutate(donor_code = as.character(donor_code)) %>%
      distinct(donor_code, .keep_all = TRUE)

    channel_map_ref_data <- read_csv(file.path(ref_base, "oecd_crs_channel_map.csv"), show_col_types = FALSE) %>%
      select(channel_id_code, oecd_channel_parent_name, oecd_aggregated_channel) %>%
      mutate(channel_id_code = as.character(channel_id_code)) %>%
      distinct(channel_id_code, .keep_all = TRUE)

    income_groups_ref_data <- read_csv(file.path(ref_base, "income_groups.csv"), show_col_types = FALSE) %>%
      select(de_recipientcode = Code, `Income group` = `Income group`) %>%
      distinct(de_recipientcode, .keep_all = TRUE)

    purpose_ref_data <- read_csv(file.path(ref_base, "purpose_ref.csv"), show_col_types = FALSE) %>%
      select(purpose_code, `Aggregate sectors 1`, `Aggregate sectors 2`, `Aggregate sectors 3`,
             `Aggregate sectors 4`, IDRC, `IDRC WASH SP`, `Non-transfer`, `Non-transfer WASH SP`) %>%
      mutate(purpose_code = as.character(purpose_code)) %>%
      distinct(purpose_code, .keep_all = TRUE)

    recipients_ref_data <- read_csv(file.path(ref_base, "Recipients_regions_ref.csv"), show_col_types = FALSE) %>%
      select(recipient_code, `Region aggregated 1`, `Region aggregated 2`) %>%
      mutate(recipient_code = as.character(recipient_code)) %>%
      distinct(recipient_code, .keep_all = TRUE)

    aid_types_raw_data <- read_csv(file.path(ref_base, "aid_types_ref.csv"), col_names = FALSE, show_col_types = FALSE)
    aid_types_ref_data <- aid_types_raw_data %>%
      select(aid_t = 2, `Bilateral allocable` = 5) %>%
      filter(!is.na(aid_t) & aid_t != "")

    # Apply reference lookups
    c_crs_data <- c_crs_data %>%
      mutate(
        donor_code_chr = as.character(donor_code),
        channel_code_chr = as.character(channel_code),
        purpose_code_chr = as.character(purpose_code),
        recipient_code_chr = as.character(recipient_code)
      ) %>%
      left_join(donor_type_ref_data, by = c("donor_code_chr" = "donor_code")) %>%
      left_join(channel_map_ref_data, by = c("channel_code_chr" = "channel_id_code")) %>%
      mutate(
        oecd_channel_parent_name = coalesce(oecd_channel_parent_name, "Unspecified"),
        oecd_aggregated_channel  = coalesce(oecd_aggregated_channel, "Unspecified")
      ) %>%
      left_join(income_groups_ref_data, by = "de_recipientcode") %>%
      mutate(`Income group` = coalesce(`Income group`, "Regional and unspecified")) %>%
      left_join(purpose_ref_data, by = c("purpose_code_chr" = "purpose_code")) %>%
      mutate(
        `Non-transfer` = if_else(is.na(`Non-transfer`) | `Non-transfer` == "", "0", `Non-transfer`),
        `Non-transfer WASH SP` = if_else(is.na(`Non-transfer WASH SP`) | `Non-transfer WASH SP` == "", "0", `Non-transfer WASH SP`)
      ) %>%
      left_join(recipients_ref_data, by = c("recipient_code_chr" = "recipient_code")) %>%
      mutate(`Climate type` = case_when(
        suppressWarnings(as.numeric(coalesce(as.character(climate_mitigation), "0"))) > 0 &
          suppressWarnings(as.numeric(coalesce(as.character(climate_adaptation), "0"))) > 0 ~ "both",
        suppressWarnings(as.numeric(coalesce(as.character(climate_mitigation), "0"))) > 0 ~ "mitigation",
        suppressWarnings(as.numeric(coalesce(as.character(climate_adaptation), "0"))) > 0 ~ "adaptation",
        TRUE ~ "neither"
      )) %>%
      left_join(aid_types_ref_data, by = "aid_t") %>%
      mutate(`Bilateral allocable` = coalesce(`Bilateral allocable`, "N")) %>%
      mutate(
        `Topical category 1` = case_when(
          c_summary == "Y" ~ "Child-related",
          as.character(sector_code) == "930" ~ "IDRC",
          as.character(recipient_code) == "85" ~ "Ukraine",
          as.character(purpose_code) == "12264" | str_detect(coalesce(as.character(keywords), ""), fixed("#COVID-19")) ~ "Covid",
          TRUE ~ "all other"
        ),
        `Topical category 2` = case_when(
          as.character(sector_code) == "930" ~ "IDRC",
          as.character(recipient_code) == "85" ~ "Ukraine",
          as.character(purpose_code) == "12264" | str_detect(coalesce(as.character(keywords), ""), fixed("#COVID-19")) ~ "Covid",
          TRUE ~ "all other"
        )
      ) %>%
      select(-donor_code_chr, -channel_code_chr, -purpose_code_chr, -recipient_code_chr)

    message("Reference file lookups complete.")
  }
}

# ----------------------------------------------------------------------------------
# --- FINAL STEP: SAVE NON-AGGREGATED DATA ---
# ----------------------------------------------------------------------------------

# Define output path and filename (relative to script location)
base_path <- "./output"
output_base_filename <- "c_crs_processed_data_from_parquet_2026"
full_suffix <- if (include_reference_files) "_full" else ""

if (!is.null(donor_filter_name) && donor_filter_name != "") {
  clean_donor_name <- str_replace_all(donor_filter_name, " ", "_")
  output_filename <- paste0(output_base_filename, "_", clean_donor_name, full_suffix, ".csv")
} else {
  output_filename <- paste0(output_base_filename, "_all_donors", full_suffix, ".csv")
}

output_csv_path <- file.path(base_path, output_filename)
output_dir <- dirname(output_csv_path)

if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

# Write output
write_csv(c_crs_data, output_csv_path, na = "")
message("Data saved to: ", output_csv_path, " (", nrow(c_crs_data), " rows, ", ncol(c_crs_data), " columns)")

# Cleanup
rm(crs_data_original_names, c_crs_data)
gc()
message("Memory cleanup complete.")
