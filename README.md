# 🧬 Interactive NGS Automation Pipeline: A Beginner's Guide

Welcome! If you have raw DNA sequencing data (FASTQ files) and want to process it but have little to no bioinformatics experience, you are in the right place. 

This repository contains a suite of **interactive, highly secure Bash scripts**. Instead of forcing you to memorize complex terminal commands, these scripts will act like a helpful assistant. You simply run a script, and it will ask you plain-English questions (like "Where is your data?" or "How much RAM do you want to use?") and then run the heavy bioinformatics software for you under the hood.

---

## 🗺️ What Does This Pipeline Do?

This toolkit helps you perform the two most common tasks in genomics:
1. **Genome Assembly & Annotation:** Taking raw fragments of DNA, stitching them together into a full genome (Assembly), and finding out where the genes are (Annotation).
2. **Variant Calling:** Comparing your DNA sample to a known "reference" genome to find mutations, and predicting what those mutations do.

Here is what each script does:
* `trim_fastp.sh`: Cleans your raw data by removing low-quality DNA sequences and adapter junk.
* `spades_assembly.sh`: Stitches your cleaned reads together into long continuous sequences (contigs).
* `quast.sh`: Checks the quality of your newly assembled genome.
* `prokka_annotation.sh`: Scans your assembled genome to find and label genes.
* `align_pipeline.sh`: Maps your reads against a reference genome.
* `bcf_variant_analysis.sh`: Finds the exact spots where your sample's DNA differs from the reference (mutations/variants).
* `snpeff_variant_annotation.sh`: Analyzes those mutations to tell you if they break a gene or change a protein.

---

## ⚙️ Step 1: Install the Bioinformatics Software

Our scripts are "wrappers"—they automate the hard parts, but you still need the actual bioinformatics software installed on your computer. 

To do this easily without breaking your computer, we use a package manager called **Conda**. Conda creates isolated "environments" (like mini-computers inside your computer) so different software tools don't interfere with each other.

### 1a. Install Miniconda (If you don't already have it)
Open your terminal and copy-paste these lines one by one. *(Note: These instructions are for Linux/Ubuntu or Windows Subsystem for Linux (WSL), which is the standard for bioinformatics).*

```bash
# Download the Miniconda installer
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

# Run the installer (Press Enter to scroll through the license, type 'yes' to accept)
bash Miniconda3-latest-Linux-x86_64.sh

# Refresh your terminal to activate Conda
source ~/.bashrc
```

### 1b. Tell Conda Where to Find Bioinformatics Tools
Run these three commands once to connect Conda to the biological software databases:
```bash
conda config --add channels defaults
conda config --add channels bioconda
conda config --add channels conda-forge
```

### 1c. Create Your Environments and Install the Tools
Because some programs require different versions of Python or Perl, we will create three separate environments to keep things clean. Copy and paste these exactly:

**Environment 1: The Main Tools (fastp, SPAdes, BWA, etc.)**
```bash
conda create -n ngs_env fastp fastqc spades bwa samtools bcftools snpeff snpsift -y
```

**Environment 2: Prokka (For Gene Finding)**
```bash
conda create -n prokka_env prokka -y
```

**Environment 3: QUAST (For Assembly Quality)**
```bash
conda create -n quast_env python=3.10 quast setuptools -y
```

---

## 📥 Step 2: Download This Toolkit

Now that your computer has the scientific software, let's download the automation scripts from this repository.

1. In your terminal, navigate to the folder where you want to do your work.
2. Download the scripts using Git:
   ```bash
   git clone https://github.com/YOUR_USERNAME/YOUR_REPOSITORY_NAME.git
   ```
   *(Be sure to replace the URL above with the actual link to your repository).*
3. Move into the new folder:
   ```bash
   cd YOUR_REPOSITORY_NAME
   ```
4. **CRITICAL STEP:** Make the scripts executable so your computer is allowed to run them:
   ```bash
   chmod +x *.sh
   ```

---

## 🚀 Step 3: How to Run the Scripts (Step-by-Step)

To run a script, you must first **activate the correct environment**, and then **run the script file**. 

Here are the two main workflows you can follow. Move your raw `.fastq.gz` data files into this folder before you begin.

### Workflow A: "I want to build and annotate a whole genome."

**1. Clean the Data:**
```bash
conda activate ngs_env
./trim_fastp.sh
```
*(The script will ask you to press Enter to find your data. It will output cleaned files into a folder called `trimmed_data`)*.

**2. Assemble the Genome:**
```bash
# Keep ngs_env activated
./spades_assembly.sh
```
*(When prompted, tell it to use the "Trimmed reads" from step 1. It will output a file called `contigs.fasta`)*.

**3. Check the Quality of the Assembly:**
```bash
conda activate quast_env
./quast.sh
```
*(Point it to your `contigs.fasta` file. It will tell you if your assembly is good or heavily fragmented).*

**4. Find the Genes (Annotation):**
```bash
conda activate prokka_env
./prokka_annotation.sh
```
*(Point it to your `contigs.fasta` file. It will output a `.gff` and `.faa` file containing all your genes and proteins).*

---

### Workflow B: "I want to find mutations compared to a reference genome."

*Note: For this, you need your raw `.fastq.gz` reads AND a reference genome `.fasta` file.*

**1. Clean the Data:**
```bash
conda activate ngs_env
./trim_fastp.sh
```

**2. Map/Align Reads to the Reference:**
```bash
# Keep ngs_env activated
./align_pipeline.sh
```
*(This will ask you for your Reference Genome file and your trimmed reads, and will output a sorted `.bam` file).*

**3. Find the Mutations (Variant Calling):**
```bash
# Keep ngs_env activated
./bcf_variant_analysis.sh
```
*(This will read the `.bam` file and output a `.vcf` file containing a list of all mutations).*

**4. Predict What the Mutations Do:**
```bash
# Keep ngs_env activated
./snpeff_variant_annotation.sh
```
*(This will output a human-readable Excel-style spreadsheet telling you which genes were mutated and if the mutation is dangerous).*

---

## 🛡️ Built-in Safety & Troubleshooting

* **You Can't Break It:** These scripts use strict security rules (`set -u` and `set -o pipefail`). If something is missing or goes wrong, the script will instantly stop itself before accidentally deleting or corrupting your data.
* **Auto-Cleanup:** Temporary junk files are automatically deleted, saving your hard drive space.
* **Learning the Ropes:** Every time a script finishes (or if it fails), it prints out the exact "manual" terminal command it used. This helps you learn how bioinformatics works under the hood!
