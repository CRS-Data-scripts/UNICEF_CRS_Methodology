# UNICEF MUMS Imputation Script (27-02-2026)
# Loads MUMS contributions, joins CRS references, and computes imputed child-focus amounts.


# Set locale to UTF-8 for special character handling
tryCatch(Sys.setlocale("LC_ALL", "en_US.UTF-8"), error = function(e) message("Could not set locale to en_US.UTF-8."))

# 1. Define all necessary file paths
file_path <- "/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/CRS files 2026/MultiSystem entire dataset.txt"
ref_file_path <- "./input/reference_files/MUMS CRS Reference.csv"
# NOTE: MUMS CRS Reference.csv is a bespoke lookup table mapping MUMS channel codes to CRS donor codes.
# It is not auto-generated and must be reviewed for completeness each time this methodology is re-run,
# particularly to capture any newly added or renamed multilaterals in the OECD CRS channel code list.
# HIPC and MIGA are not mapped in this reference file: HIPC is locked to purpose code 600
# (Debt Relief) with no sectoral disaggregation available; MIGA activity is largely OOF rather
# than ODA with no cash disbursements to impute from. IDA is mapped as a standard multilateral.
# Path to CRS multilateral aggregated data with child-focus percentages
crs_multi_agg_path <- "./output/c_crs_multi_aggregated_parquet_wide.csv"

# 2. Import the data using the high-performance 'data.table::fread()' function.
tryCatch({
  
  # --- 2a. Load or Install the data.table package for fast import ---
  if (!requireNamespace("data.table", quietly = TRUE)) {
    install.packages("data.table")
  }
  library(data.table)
  
  # --- 2b. Import the main data using fread() ---
  data_table <- data.table::fread(
    file = file_path, 
    sep = "|",
    encoding = "UTF-8",
    fill = TRUE,
    na.strings = character(0),
    data.table = FALSE
  )
  
  cat("Data imported:", nrow(data_table), "rows,", ncol(data_table), "columns\n\n")
  
  # --- 5. Import and Join First Reference Data ---
  cat("Importing reference data...\n")
  
  # 5a. Import the CRS Reference data
  crs_ref <- data.table::fread(
    file = ref_file_path,
    sep = ",", # Assuming the reference file is a standard CSV
    encoding = "UTF-8",
    data.table = FALSE 
  )
  
  required_ref_cols <- c("ChannelCode", "CRS Donor name", "CRS Donor code")
  
  if (all(required_ref_cols %in% names(crs_ref)) && "ChannelCode" %in% names(data_table)) {
    
    # Select only the necessary columns from the reference table
    crs_ref_selected <- crs_ref[, required_ref_cols]

    cat("Joining with CRS reference data...\n")
    
    data_table <- merge(
      x = data_table, 
      y = crs_ref_selected, 
      by = "ChannelCode", 
      all.x = TRUE
    )
    
    cat("Join complete.\n\n")
    
  } else {
    cat(paste("Warning: Join skipped. Check if 'ChannelCode' exists in main data and (", paste(required_ref_cols, collapse=", "), ") exist in the reference file.\n\n"))
  }
  
  
  cat("Filtering data...\n")
  
  required_cols_filter <- c("AidToOrThru", "Year", "AmountType", "FlowType")
  if (all(required_cols_filter %in% names(data_table))) {
    initial_rows <- nrow(data_table)
    
    # Perform the combined filtering operation
    data_table <- data_table[
      data_table$AidToOrThru == 'Core contributions to' & 
        data_table$Year >= 2014 &
        data_table$AmountType == 'Constant prices' &
        data_table$FlowType == 'Disbursements',
    ]
    
    filtered_rows <- nrow(data_table)
    cat("Rows kept:", filtered_rows, "\n\n")
  } else {
    cat(paste("Warning: Filtering skipped. Required columns (", paste(required_cols_filter, collapse=", "), ") not found. Please check the spelling.\n\n"))
  }
  
  cat("Aggregating data...\n")

  # Keep rows with missing amounts by treating blanks/NA as zero before aggregation
  if ("Amount" %in% names(data_table)) {
    data_table$Amount <- suppressWarnings(as.numeric(data_table$Amount))
    missing_amount_count <- sum(is.na(data_table$Amount))
    if (missing_amount_count > 0) {
      data_table$Amount[is.na(data_table$Amount)] <- 0
      cat("Amount cleanup:", missing_amount_count, "missing values set to 0 before aggregation.\n")
    }
  }
  
  # Group by year, MUMS donor/channel identifiers, and CRS donor identifiers
  grouping_vars <- c("Year", "DonorNameE", "DonorCode", "ChannelNameE", "ChannelCode", "CRS Donor name", "CRS Donor code")
  
  if (all(grouping_vars %in% names(data_table)) && "Amount" %in% names(data_table)) {
    
    # FIX: Wrap column names in backticks (`) when creating the formula to handle spaces in column names.
    escaped_grouping_vars <- paste0("`", grouping_vars, "`")
    
    # Construct the formula dynamically using the escaped column names
    aggregation_formula <- as.formula(paste("Amount ~", paste(escaped_grouping_vars, collapse = " + ")))
    
    aggregated_data <- aggregate(
      aggregation_formula,
      data = data_table,
      FUN = sum
    )
    
    data_table <- as.data.frame(aggregated_data)
    
    cat("Aggregation complete.\n")
    
    cat("Renaming columns...\n")
    
    # Define mapping of old names (which may contain spaces) to new names (snake_case)
    name_map <- c(
      "DonorNameE" = "MUMS_donor_name",
      "DonorCode" = "MUMS_donor_code",
      "ChannelNameE" = "MUMS_channel_name",
      "ChannelCode" = "MUMS_channel_code",
      "CRS Donor name" = "CRS_multi_donor_name",
      "CRS Donor code" = "CRS_multi_donor_code",
      "Amount" = "MUMS_amount" # Renaming 'Amount' as requested
    )
    
    # Replace existing column names using the map
    # We iterate through the map and rename the columns in data_table
    for (old_name in names(name_map)) {
      new_name <- name_map[old_name]
      # Check if the old column name exists before trying to rename it
      if (old_name %in% names(data_table)) {
        names(data_table)[names(data_table) == old_name] <- new_name
      } else {
        cat(paste("Warning: Column '", old_name, "' not found for renaming.\n"))
      }
    }
    
    cat("Renaming complete.\n\n")
    
  } else {
    cat(paste("Warning: Aggregation skipped. One or more required columns (", paste(c(grouping_vars, "Amount"), collapse=", "), ") not found. Check if the join was successful.\n\n"))
  }
  
  cat("Joining with CRS multi aggregated data...\n")
  
  # 8a. Import the second reference data
  crs_agg_ref <- data.table::fread(
    file = crs_multi_agg_path,
    sep = ",", # Assuming a standard CSV
    encoding = "UTF-8",
    data.table = FALSE 
  )
  
  # Columns to keep from the reference file, plus the join keys
  required_agg_cols <- c("year", "donor_code", "usd_defl_child_focus", "usd_defl_other", "usd_defl_total", "child_focus_percent_5year")
  
  if (all(required_agg_cols %in% names(crs_agg_ref)) && all(c("Year", "CRS_multi_donor_code") %in% names(data_table))) {
    
    # Select only necessary columns from the second reference table
    crs_agg_ref_selected <- crs_agg_ref[, required_agg_cols]
    
    # 8b. Perform a Left Join (merge) on two keys: Year/year AND CRS_multi_donor_code/donor_code
    data_table$CRS_multi_donor_code <- as.character(data_table$CRS_multi_donor_code)
    crs_agg_ref_selected$donor_code <- as.character(crs_agg_ref_selected$donor_code)

    data_table <- merge(
      x = data_table, 
      y = crs_agg_ref_selected, 
      by.x = c("Year", "CRS_multi_donor_code"), # Keys in the aggregated data
      by.y = c("year", "donor_code"),           # Keys in the reference file
      all.x = TRUE # Left Join: keeps all aggregated rows
    )

    # 8c. Fallback fill for child-focus percentage by donor code only
    # Keeps annual CRS volume fields (usd_defl_*) as NA when year-level rows are missing
    crs_child_focus_ref <- crs_agg_ref_selected[
      !is.na(crs_agg_ref_selected$child_focus_percent_5year),
      c("donor_code", "child_focus_percent_5year")
    ]
    crs_child_focus_ref <- crs_child_focus_ref[!duplicated(crs_child_focus_ref$donor_code), ]
    crs_child_focus_ref$donor_code <- as.character(crs_child_focus_ref$donor_code)

    data_table <- merge(
      x = data_table,
      y = crs_child_focus_ref,
      by.x = "CRS_multi_donor_code",
      by.y = "donor_code",
      all.x = TRUE,
      suffixes = c("", "_fallback")
    )

    if (all(c("child_focus_percent_5year", "child_focus_percent_5year_fallback") %in% names(data_table))) {
      missing_pct_idx <- is.na(data_table$child_focus_percent_5year)
      data_table$child_focus_percent_5year[missing_pct_idx] <- data_table$child_focus_percent_5year_fallback[missing_pct_idx]
      data_table$child_focus_percent_5year_fallback <- NULL
    }
    
    cat("Second join complete.\n\n")
    
  } else {
    cat("Warning: Second join skipped. Required columns in either file are missing. Check keys and value columns.\n\n")
  }
  # --------------------------------------------------------------------------------
  
  cat("Renaming CRS columns...\n")
  
  # Define mapping of old names to new names
  name_map_crs <- c(
    "usd_defl_child_focus" = "CRS_usd_defl_child_focus",
    "usd_defl_other" = "CRS_usd_defl_other",
    "usd_defl_total" = "CRS_usd_defl_total",
    "child_focus_percent_5year" = "CRS_child_focus_pct_5yr_avg_2020_2024"
  )
  
  for (old_name in names(name_map_crs)) {
    new_name <- name_map_crs[old_name]
    if (old_name %in% names(data_table)) {
      names(data_table)[names(data_table) == old_name] <- new_name
    } else {
      cat(paste("Warning: Column '", old_name, "' not found for renaming (CRS prefixing).\n"))
    }
  }
  cat("Renaming complete.\n")
  
  
  cat("Calculating imputed amounts...\n")
  
  # Apply CRS child-focus percentage to MUMS amounts
  if (all(c("CRS_child_focus_pct_5yr_avg_2020_2024", "MUMS_amount") %in% names(data_table))) {
    data_table$imputed_child_focus_amount <- data_table$CRS_child_focus_pct_5yr_avg_2020_2024 * data_table$MUMS_amount
    cat("Calculation complete.\n")
  } else {
    cat("Warning: Calculation skipped. 'CRS_child_focus_pct_5yr_avg_2020_2024' or 'MUMS_amount' columns not found. Check if the second join and aggregation were successful.\n\n")
  }
  
  cat("Reordering columns...\n")
  
  # Define the desired final order of the columns
  current_cols <- names(data_table)
  
  # 1. Fixed starting columns in the desired order
  fixed_start_cols <- c(
    "Year", 
    "MUMS_donor_name", 
    "MUMS_donor_code", 
    "MUMS_channel_name", 
    "MUMS_channel_code", 
    "MUMS_amount",
    "CRS_multi_donor_name",
    "CRS_multi_donor_code"
  )
  
  # 2. Automatically find the remaining columns (joined/calculated)
  # This includes the newly calculated and CRS_ prefixed columns
  remaining_cols <- setdiff(current_cols, fixed_start_cols)
  
  # 3. Create the final new order
  new_col_order <- c(fixed_start_cols, remaining_cols)
  
  # Apply the new order, filtering to only keep columns that actually exist
  cols_to_keep <- new_col_order[new_col_order %in% current_cols]
  
  data_table <- data_table[, cols_to_keep]
  
  cat("Column reordering complete.\n\n")
  
  
  cat("Exporting detailed data to c_imputation_calcs.csv...\n")
  
  # Define the output directory and filename
  output_dir <- "./output" 
  output_filename_detailed <- "c_imputation_calcs.csv" 
  output_path_detailed <- file.path(output_dir, output_filename_detailed)
  output_filename_summary <- "c_imputation_agg.csv"
  output_path_summary <- file.path(output_dir, output_filename_summary)
  
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE)
  }
  
  data.table::fwrite(
    x = data_table,
    file = output_path_detailed,
    sep = ",",
    row.names = FALSE,
    encoding = "UTF-8"
  )
  
  cat("Detailed data saved to:", output_path_detailed, "\n\n")
  
  cat("Aggregating and exporting summary data to c_imputation_agg.csv...\n")
  
  grouping_vars_final <- c("Year", "MUMS_donor_name", "MUMS_donor_code")
  
  if (all(grouping_vars_final %in% names(data_table)) && "imputed_child_focus_amount" %in% names(data_table)) {
    
    # 10a. Construct the formula
    escaped_grouping_vars_final <- paste0("`", grouping_vars_final, "`")
    aggregation_formula_final <- as.formula(paste("imputed_child_focus_amount ~", paste(escaped_grouping_vars_final, collapse = " + ")))
    
    # 10b. Perform the aggregation
    imputation_agg_data <- aggregate(
      aggregation_formula_final,
      data = data_table,
      FUN = sum
    )
    
    imputation_agg_data <- as.data.frame(imputation_agg_data)
    
    cat("Summary aggregation complete.\n")
    
    data.table::fwrite(
      x = imputation_agg_data,
      file = output_path_summary,
      sep = ",", 
      row.names = FALSE,
      encoding = "UTF-8"
    )
    
    cat("Summary data saved to:", output_path_summary, "\n")
    
  } else {
    cat("Warning: Summary aggregation skipped. Required columns not found.\n")
  }
  
}, error = function(e) {
  # General error handling
  cat(paste("An unrecoverable error occurred during import or processing:\n", e$message, "\n"))
  cat("Please double-check the 'file_path', 'ref_file_path', and ensure the data.table package is installed.\n")
})

# ----------------------------------------------------------------------------------
# --- CLEANUP: Free memory after processing ---
# ----------------------------------------------------------------------------------

# Remove large data objects to free memory
rm(list = intersect(c(
  "data_table",
  "crs_ref",
  "crs_ref_selected",
  "aggregated_data",
  "crs_agg_ref",
  "crs_agg_ref_selected",
  "imputation_agg_data"
), ls()))

# Force garbage collection to release memory back to the system
gc()

cat("Memory cleanup complete. Environment cleared.\n")
