# UNICEF Child-Focused ODA Pipeline — GitHub Setup Guide

Welcome! This guide explains how to set up the pipeline on your machine.

## Quick Start

### 1. Clone or download this repository
```bash
git clone https://github.com/unicef-drp/[REPO_NAME].git
cd [REPO_NAME]
```

### 2. Download the CRS Parquet file
The pipeline requires a CRS parquet file that is **not included** in this repository (file size ~1GB+).

**Steps to download:**
1. Visit the [OECD Data Explorer](https://data-explorer.oecd.org/)
2. Search for: **"CRS: Creditor Reporting System (flows)"**
3. Click **Download** and select the **Parquet** format
4. Place the downloaded file in: `input/CRS.parquet`

### 3. Verify directory structure
After downloading the parquet file, your folder should look like this:
```
├── README.md
├── SETUP.md (this file)
├── scripts/
│   ├── 01_donor_classification.R
│   ├── 02_cf_summary.R
│   ├── 03_multilateral_classification.R
│   └── 04_mums_imputation.R
├── input/
│   ├── CRS.parquet (← YOU NEED TO ADD THIS)
│   └── reference_files/
│       ├── donor_type_ref.csv
│       ├── purpose_ref.csv
│       └── [other reference files]
└── output/
    └── (generated outputs will appear here)
```

### 4. Run the scripts in RStudio
1. Open `scripts/01_donor_classification.R` (or whichever script you need)
2. All file paths are **relative**, so they will work on any machine
3. Configure the user-settable options at the top of each script (e.g., donor name, filters)
4. Run the script
5. Outputs will be saved to the `output/` folder

---

## File Structure Overview

| Folder | Purpose |
|---|---|
| `scripts/` | Four R scripts implementing the analytical pipeline |
| `input/reference_files/` | Lookup files (donor codes, sector classifications, etc.) |
| `input/CRS.parquet` | **You must download this separately** from OECD |
| `output/` | Generated CSV and Excel outputs (created by scripts) |

---

## Reference Files

All reference files (CSV format) are included:
- **donor_type_ref.csv** — Maps donors to classifications (DAC, multilateral, etc.)
- **purpose_ref.csv** — OECD purpose code to sector mappings
- **MUMS CRS Reference.csv** — Bridge file for MUMS–CRS mappings
- **oecd_crs_channel_map.csv** — Channel taxonomy
- **Recipients_regions_ref.csv** — Country to region mappings
- **income_groups.csv** — World Bank income group classifications
- Other supporting reference files

**Important:** These reference files can become outdated as OECD taxonomies change. See the main [README.md](README.md) for details on which files may need updating.

---

## Script Execution Order

**For standalone analyses:**
- Run any single script independently (e.g., just the donor script, or just the CF summary)

**For multilateral imputation workflow:**
1. Run `03_multilateral_classification.R` first → produces `c_crs_multi_aggregated_parquet_wide.csv`
2. Then run `04_mums_imputation.R` → uses the output from step 1

---

## Configuring the Scripts

Each script has a **"User-configurable settings"** section at the top where you can set:
- Donor name filters
- Year thresholds
- Which flags to extract
- Whether to include reference file lookups
- And more

Open a script in your R editor and look for the comment section with `# ---` to find these settings.

---

## Troubleshooting

### "Parquet file not found" error
→ Check that `input/CRS.parquet` exists at the correct path relative to your script

### "Reference file not found" error
→ Ensure the `input/reference_files/` folder contains all `.csv` files with the correct names

### R package installation fails
→ The scripts include an `ensure_package()` function that will attempt to install missing packages automatically

### Locale/encoding issues with special characters
→ The scripts set UTF-8 locale by default, but this may vary by OS. See the first few lines of each script for details.

---

## Data & Reproducibility

**Important notes:**
- All scripts are deterministic: same input data + same configuration = identical output
- The pipeline follows UN Fundamental Principles of Official Statistics
- See [README.md](README.md) for full methodology, code definitions, and reproducibility details

---

## Next Steps

1. ✅ Download the CRS parquet file
2. ✅ Place it in `input/CRS.parquet`
3. ✅ Open and configure your chosen script in RStudio
4. ✅ Run it and check the `output/` folder for results

---

## Questions or Issues?

For questions about the methodology, see [README.md](README.md).  
For technical issues with OECD data access, see [OECD Data Explorer](https://data-explorer.oecd.org/).

---

**Last updated:** 2026-06-17
