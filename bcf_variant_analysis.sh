#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# -u: Exit on undefined variables to prevent catastrophic empty path expansion
# -o pipefail: Ensures errors in piped commands are not hidden
set -u
set -o pipefail

# Secure temporary error log with automatic cleanup
ERROR_LOG=$(mktemp -t variant_err_XXXXXX.log)
trap 'rm -f "$ERROR_LOG"' EXIT INT TERM HUP

echo "========================================================"
echo "    SECURE BCFTOOLS VARIANT CALLING & FILTERING         "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual commands on BOTH success and failure
print_manual_commands() {
    local bam="${BAM_FILE:-<aligned.sorted.bam>}"
    local ref="${REF_FILE:-<ref.fasta>}"
    local pref="${PREFIX:-sample}"
    local out_bcf="${OUT_BCF:-results/bcf/${pref}_raw.bcf}"
    local out_vcf="${OUT_VCF:-results/vcf/${pref}_variants.vcf}"
    local out_final="${OUT_FINAL:-results/vcf/${pref}_final_variants.vcf}"
    local ploidy="${PLOIDY:-1}"
    local t="${THREADS:-4}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN VARIANT CALLING MANUALLY NEXT TIME:"
    echo "You can bypass this script and run the steps directly:"
    echo ""
    echo "1. Calculate read coverage (mpileup):"
    echo "   bcftools mpileup -O b -o ${out_bcf} -f${ref} --threads ${t}${bam}"
    echo ""
    echo "2. Call SNVs & Indels:"
    echo "   bcftools call --ploidy ${ploidy} -m -v -o${out_vcf} --threads ${t}${out_bcf}"
    echo ""
    echo "3. Filter variants by quality:"
    echo "   vcfutils.pl varFilter ${out_vcf} >${out_final}"
    echo ""
    echo "4. View alignment manually:"
    echo "   samtools tview ${bam}${ref}"
    echo "========================================================"
}

# ========================================================
# 2. DEPENDENCY CHECK
# ========================================================
MISSING_TOOLS=()
for tool in bcftools samtools vcfutils.pl; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

# Safely check array length to prevent unbound variable crashes under `set -u`
if (( ${#MISSING_TOOLS[@]} > 0 )); then
    echo "❌ PIPELINE FAILED: Missing required tools: ${MISSING_TOOLS[*]}"
    echo "   Fix: Run 'sudo apt install bcftools samtools' OR 'conda install -c bioconda bcftools samtools'"
    print_manual_commands
    exit 1
fi

# ========================================================
# 3. AUTO-DETECT INPUT FILES (REFERENCE & BAM)
# ========================================================
# Reference Genome
read -e -p "1. Reference genome folder (press [Enter] for current folder): " REF_DIR
REF_DIR="${REF_DIR:-.}"
REF_DIR="${REF_DIR/#\~/$HOME}"
REF_DIR="${REF_DIR%/}"

if [[ ! -d "$REF_DIR" && "$(basename "$PWD")" == "$REF_DIR" ]]; then
    REF_DIR="."
fi

# Use find instead of ls to prevent word-splitting on weird filenames
DEFAULT_REF=$(find "$REF_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*\.(fasta|fa|fna)$' -exec basename {} \; 2>/dev/null | head -n 1)
read -e -p "2. Enter reference genome filename (press [Enter] for '${DEFAULT_REF:-none}'): " REF_NAME
REF_NAME="${REF_NAME:-$DEFAULT_REF}"
REF_FILE="${REF_DIR}/${REF_NAME}"

# Absolute path resolution
REF_FILE=$(readlink -f "$REF_FILE" 2>/dev/null || realpath "$REF_FILE" 2>/dev/null \vert{}\vert{} echo "$REF_FILE")

if [[ ! -f "$REF_FILE" \vert{}\vert{} ! -s "$REF_FILE" ]]; then
    echo "❌ PIPELINE FAILED: Reference file '$REF_FILE' is missing or empty!"
    exit 1
fi

echo "--------------------------------------------------------"
# BAM File
read -e -p "3. BAM file folder (press [Enter] for current folder): " BAM_DIR
BAM_DIR="${BAM_DIR:-.}"
BAM_DIR="${BAM_DIR/#\~/$HOME}"
BAM_DIR="${BAM_DIR%/}"

if [[ ! -d "$BAM_DIR" && "$(basename "$PWD")" == "$BAM_DIR" ]]; then
    BAM_DIR="."
fi

DEFAULT_BAM=$(find "$BAM_DIR" -maxdepth 1 -type f -name "*_sorted.bam" -exec basename {} \; 2>/dev/null | head -n 1)
read -e -p "4. Enter sorted BAM filename (press [Enter] for '${DEFAULT_BAM:-none}'): " BAM_NAME
BAM_NAME="${BAM_NAME:-$DEFAULT_BAM}"
BAM_FILE="${BAM_DIR}/${BAM_NAME}"
BAM_FILE=$(readlink -f "$BAM_FILE" 2>/dev/null || realpath "$BAM_FILE" 2>/dev/null \vert{}\vert{} echo "$BAM_FILE")

if [[ ! -f "$BAM_FILE" \vert{}\vert{} ! -s "$BAM_FILE" ]]; then
    echo "❌ PIPELINE FAILED: BAM file '$BAM_FILE' is missing or empty!"
    exit 1
fi

# ========================================================
# 4. PARAMETERS & DIRECTORY SETUP
# ========================================================
echo "--------------------------------------------------------"
GUESSED_SAMPLE=$(basename "$BAM_FILE" \vert{} sed -E 's/\.(aligned\.)?sorted\.bam$//')
read -p "5. Enter Sample ID for output prefix (press [Enter] for '$GUESSED_SAMPLE'): " PREFIX
PREFIX="${PREFIX:-$GUESSED_SAMPLE}"
PREFIX=$(echo "$PREFIX" | tr -cd 'A-Za-z0-9_-') # Sanitize against injection

read -p "6. Enter organism ploidy (1 for haploid like E. coli, 2 for human/diploid. Default: 1): " PLOIDY
PLOIDY="${PLOIDY:-1}"
if ! [[ "$PLOIDY" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ PIPELINE FAILED: Ploidy must be a positive whole number."
    exit 1
fi

MAX_CORES=$(nproc 2>/dev/null || echo 4)
DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
read -p "7. CPU threads to use (Detected $MAX_CORES cores; default:$DEF_THREADS): " THREADS
THREADS="${THREADS:-$DEF_THREADS}"
if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ PIPELINE FAILED: Threads must be a positive whole number."
    exit 1
fi

read -e -p "8. Output folder name (press [Enter] for 'results'): " OUT_DIR
OUT_DIR="${OUT_DIR:-results}"
OUT_DIR="${OUT_DIR/#\~/$HOME}"
OUT_DIR="${OUT_DIR%/}"

# Safely create output directories
if ! mkdir -p "${OUT_DIR}/bcf" "${OUT_DIR}/vcf" 2>/dev/null; then
    echo "❌ PIPELINE FAILED: Could not create output directories in '$OUT_DIR' (Permission denied)."
    exit 1
fi

OUT_BCF="${OUT_DIR}/bcf/${PREFIX}_raw.bcf"
OUT_VCF="${OUT_DIR}/vcf/${PREFIX}_variants.vcf"
OUT_FINAL="${OUT_DIR}/vcf/${PREFIX}_final_variants.vcf"

# Index the BAM file securely, warning if the directory is read-only
if [[ ! -f "${BAM_FILE}.bai" ]]; then
    echo "⚙ BAM index missing. Checking write permissions..."
    if [[ ! -w $(dirname "$BAM_FILE") ]]; then
        echo "❌ PIPELINE FAILED: You do not have permission to write to the folder containing the BAM file."
        echo "   'samtools index' must generate the '.bai' file inside '$(dirname "$BAM_FILE")'."
        exit 1
    fi
    samtools index -@ "$THREADS" "$BAM_FILE"
fi

# ========================================================
# 5. SECURE PIPELINE EXECUTION (VIA BASH ARRAYS)
# ========================================================
echo "========================================================"
echo "✔ Reference Genome : $REF_FILE"
echo "✔ Aligned BAM      : $BAM_FILE"
echo "✔ Ploidy           : $PLOIDY"
echo "✔ Output Directory : $OUT_DIR/"
echo "========================================================"
echo "⏳ Step 1/3: Calculating read coverage (mpileup)..."

CMD_MPILEUP=(bcftools mpileup -O b -o "$OUT_BCF" -f "$REF_FILE" --threads "$THREADS" "$BAM_FILE")
if ! "${CMD_MPILEUP[@]}" 2> >(tee -a "$ERROR_LOG" >&2); then
    echo "❌ FAILED DURING 'bcftools mpileup'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved intermediate BCF: $OUT_BCF"

echo ""
echo "⏳ Step 2/3: Calling SNVs/Indels (call)..."
CMD_CALL=(bcftools call --ploidy "$PLOIDY" -m -v -o "$OUT_VCF" --threads "$THREADS" "$OUT_BCF")
if ! "${CMD_CALL[@]}" 2> >(tee -a "$ERROR_LOG" >&2); then
    echo "❌ FAILED DURING 'bcftools call'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved raw VCF: $OUT_VCF"

echo ""
echo "⏳ Step 3/3: Filtering variants (vcfutils.pl)..."
# Using a subshell to prevent set -o pipefail from triggering incorrectly if tee writes slower than stdout
if ! bash -c "vcfutils.pl varFilter \"$OUT_VCF\" > \"$OUT_FINAL\" 2> >(tee -a \"$ERROR_LOG\" >&2)"; then
    echo "❌ FAILED DURING 'vcfutils.pl varFilter'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi

if [[ ! -s "$OUT_FINAL" ]]; then
    echo "❌ PIPELINE FAILED: '$OUT_FINAL' was created but is empty."
    cat "$ERROR_LOG"
    exit 1
fi
echo "✔ Saved final VCF: $OUT_FINAL"

# ========================================================
# 6. QUALITY STATS (TS/TV RATIO) & SUMMARY
# ========================================================
echo "========================================================"
echo "✅ PIPELINE SUCCESS! Calculating sanity check metrics..."
echo "--------------------------------------------------------"

# Safely extract TS/TV ratios without breaking due to pipefail
RAW_TSTV=$(bcftools stats "$OUT_VCF" 2>/dev/null | grep "^TSTV" | head -n 1 | awk -F'\t' '{print $5}' || echo "N/A")
echo "📉 TS/TV Ratio BEFORE Filtering (Raw VCF) :   $RAW_TSTV"

FIN_TSTV=$(bcftools stats "$OUT_FINAL" 2>/dev/null | grep "^TSTV" | head -n 1 | awk -F'\t' '{print $5}' || echo "N/A")
echo "📉 TS/TV Ratio AFTER Filtering (Final VCF):   $FIN_TSTV"

VAR_COUNT=$(grep -v "^#" "$OUT_FINAL" | wc -l)
echo ""
echo "🧬 Total High-Quality Variants Kept: $VAR_COUNT"
echo "========================================================"

print_manual_commands

# ========================================================
# 7. INTERACTIVE VISUALIZATION
# ========================================================
echo ""
echo "👁️  VISUALIZATION (samtools tview)"
echo "   tview is a lightweight alignment viewer that lets you see"
echo "   your BAM reads stacked directly against the reference genome."
read -p "   Do you want to open samtools tview now? [y/N]: " OPEN_TVIEW

if [[ "$OPEN_TVIEW" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "   (Tip: Press '?' for help inside tview, and 'q' to quit.)"
    sleep 2
    samtools tview "$BAM_FILE" "$REF_FILE"
fi
