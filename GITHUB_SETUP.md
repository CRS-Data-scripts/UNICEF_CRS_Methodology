# Getting Your Code on GitHub: A Beginner's Guide

Your GitHub-ready folder is complete at:  
`/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Scripts/Github`

## What's Inside

```
Github/
├── README.md                          # Main documentation (already in place)
├── SETUP.md                           # Setup instructions for users
├── PATH_MODIFICATIONS.md              # Path modification reference (for info only)
├── .gitignore                         # Tells Git what NOT to upload
├── scripts/
│   ├── 01_donor_classification.R
│   ├── 02_cf_summary.R
│   ├── 03_multilateral_classification.R
│   └── 04_mums_imputation.R
├── input/
│   ├── CRS.parquet                   (← Users must add this - NOT included)
│   └── reference_files/              (← All 7 reference CSVs included)
└── output/                           (← Generated locally, NOT uploaded to GitHub)
```

---

## Step 1: Install Git on Your Mac

1. Download Git from: https://git-scm.com/download/mac
2. Or use Homebrew: `brew install git`
3. Verify: Open Terminal and type: `git --version`

---

## Step 2: Create a GitHub Account

1. Go to https://github.com/join
2. Sign up with your email (creates a free account)
3. Verify your email

---

## Step 3: Create a Repository on GitHub

1. Go to https://github.com/new
2. Fill in:
   - **Repository name:** `unicef-crs-child-focus` (or similar)
   - **Description:** "UNICEF Child-Focused ODA Analytical Pipeline"
   - **Visibility:** Choose "Public" (so others can access it)
   - **DO NOT initialize with README** (you already have one)
3. Click **"Create repository"**
4. GitHub will show you setup instructions - keep this page open

---

## Step 4: Upload Your Code to GitHub (Using Terminal)

### 4a. Navigate to your folder
```bash
cd '/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Scripts/Github'
```

### 4b. Initialize Git (only do this once)
```bash
git init
```

### 4c. Add all files
```bash
git add .
```

### 4d. Create your first commit
```bash
git commit -m "Initial commit: UNICEF CRS child-focus pipeline"
```

### 4e. Link to GitHub (replace `YOUR_USERNAME` and `REPO_NAME`)
```bash
git remote add origin https://github.com/YOUR_USERNAME/REPO_NAME.git
```

### 4f. Upload to GitHub
```bash
git branch -M main
git push -u origin main
```

---

## Step 5: Verify It's Online

1. Go to your GitHub repository URL: `https://github.com/YOUR_USERNAME/REPO_NAME`
2. You should see all your files, README, and folder structure

---

## Key GitHub Best Practices for Your Project

### ✅ What You Did Right:

1. **Include README.md** — Users know what the project is about
2. **Include .gitignore** — Prevents accidentally uploading:
   - Large data files (CRS.parquet - users download separately)
   - Output files (generated locally)
   - R history files
3. **Include reference files** — Users can run it without additional setup
4. **Use relative paths** — Works on any machine
5. **Document setup requirements** — Users know what to do before running

### ✅ Best Practices Going Forward:

**Use Git workflow for updates:**
```bash
# When you make changes locally:
git add .
git commit -m "Clear description of what changed"
git push

# Example messages:
git commit -m "Update keyword methodology for precision"
git commit -m "Fix donor code mapping for Australia SDG rule"
git commit -m "Add support for 2025 CRS data structure"
```

**Create releases for versions:**
- On GitHub, click "Releases" tab
- Create a new release with version number (e.g., v1.0)
- Add changelog notes
- Users can download specific versions

**For large file data:**
- Current approach is correct: users download separately
- Alternative: Use Git LFS (Git Large File Storage) for files <100MB
- For now, keep current approach (simpler for users)

---

## How GitHub Benefits Your Project

| Benefit | Why It Matters |
|---------|---|
| **Version Control** | Track every change, revert if needed |
| **Collaboration** | Others can suggest improvements (fork + pull request) |
| **Reproducibility** | Users can access exact versions you released |
| **Discovery** | Researchers find your work via GitHub search |
| **Open Science** | Supports UN principles of transparency |
| **Backup** | Your code is safely backed up online |

---

## Making It Clear for Users (What They See)

When users visit your GitHub page, they'll see:

1. **Project Title & Description** (from your README)
2. **Quick Start** (from SETUP.md)
3. **Reference files** (all included)
4. **Script structure** (organized in `scripts/` folder)
5. **.gitignore note:** They'll understand why CRS.parquet isn't included
6. **License** (optional, but recommended for open science - see below)

---

## Optional: Add a LICENSE File

This tells users how they can use your code. Add ONE of these files to your folder:

### MIT License (most permissive - recommended for research)
Create `LICENSE` file with:
```
MIT License

Copyright (c) 2026 UNICEF

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

[rest of MIT license - search online for full text]
```

Or use CC-BY 4.0 (common in UN/research): https://creativecommons.org/licenses/by/4.0/

---

## Command Reference (Quick Copy-Paste)

```bash
# First time setup
cd '/Users/duncanknox/Documents/Jobs/UNICEF/R Scripts/Scripts/Github'
git init
git config user.name "Your Name"
git config user.email "your.email@example.com"
git add .
git commit -m "Initial commit: UNICEF CRS child-focus pipeline"
git remote add origin https://github.com/YOUR_USERNAME/REPO_NAME.git
git branch -M main
git push -u origin main

# After making changes
git add .
git commit -m "Describe your changes here"
git push

# View status
git status
git log
```

---

## Accessing Later

Once on GitHub, you can:
- **Clone it** to another machine: `git clone https://github.com/YOUR_USERNAME/REPO_NAME.git`
- **Pull latest changes:** `git pull` (if working with collaborators)
- **Create branches** for experimental features: `git checkout -b new-feature`

---

## Next Steps

1. ✅ Install Git
2. ✅ Create GitHub account  
3. ✅ Create repository on GitHub
4. ✅ Run the Terminal commands from Step 4
5. ✅ Verify your repo is online
6. (Optional) Add a LICENSE file
7. Share the GitHub URL with your team/supervisor

---

## Need Help?

- **Git basics**: https://git-scm.com/book/en/v2/Getting-Started-About-Version-Control
- **GitHub docs**: https://docs.github.com/en
- **Terminal basics**: Search "git command cheat sheet" online

Good luck! 🚀
