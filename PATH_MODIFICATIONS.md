# GitHub Path Modification Guide

The scripts `02_cf_summary.R`, `03_multilateral_classification.R`, and `04_mums_imputation.R` have been copied but still contain hardcoded local paths from the original machine. 

## Quick Fix: Path Replacements

You'll need to replace the following hardcoded paths in each script. Use your text editor's "Find and Replace" feature:

### In ALL scripts (02, 03, 04):

**Find:**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/Reference files/
```

**Replace with:**
```
./input/reference_files/
```

---

### In script 02_cf_summary.R:

**Find (parquet path):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/CRS files 2026/CRS.parquet
```

**Replace with:**
```
./input/CRS.parquet
```

**Find (output path):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Output
```

**Replace with:**
```
./output
```

---

### In script 03_multilateral_classification.R:

**Find (parquet path):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/CRS files 2026/CRS.parquet
```

**Replace with:**
```
./input/CRS.parquet
```

**Find (output path):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Output
```

**Replace with:**
```
./output
```

---

### In script 04_mums_imputation.R:

**Find (input path for MUMS file):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/
```

**Replace with:**
```
./input/
```

**Find (output path):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Output
```

**Replace with:**
```
./output
```

**Find (reference file paths):**
```
/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/Reference files/
```

**Replace with:**
```
./input/reference_files/
```

---

## Step-by-Step in RStudio/VS Code:

1. Open each script file (02, 03, or 04)
2. Press `Ctrl+H` (or `Cmd+Shift+F` in VS Code) to open Find and Replace
3. For each path replacement above:
   - Enter the "Find" text
   - Enter the "Replace" text
   - Click "Replace All"
4. Save the file

---

## Alternative: Batch Path Replacement (Advanced)

If you want to do all replacements at once using terminal, you can use `sed`:

```bash
cd /Users/duncanknox/Documents/Jobs/UNICEF/R\ Scripts/Scripts/Github/scripts

# Replace hardcoded paths in all scripts
for file in 02_cf_summary.R 03_multilateral_classification.R 04_mums_imputation.R; do
  sed -i '' 's|/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/Reference files/|./input/reference_files/|g' "$file"
  sed -i '' 's|/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Input/CRS files 2026/CRS.parquet|./input/CRS.parquet|g' "$file"
  sed -i '' 's|/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Output|./output|g' "$file"
done
```

---

## Notes

- Script 01_donor_classification.R has already been modified with relative paths
- After modifying paths, you can rename these scripts to match the GitHub naming convention or keep the current names
- All relative paths assume you're running the scripts from the repository root folder (where this guide is)
- Make sure you have the `input/CRS.parquet` file downloaded before running any scripts

---

Done! Now you're ready to push to GitHub.
