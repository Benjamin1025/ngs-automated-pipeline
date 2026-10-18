#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# Enforce strict variable checking and prevent hidden pipe errors
set -u
set -o pipefail

# Secure temporary error log with automatic cleanup (prevents orphaned files)
ERROR_LOG=$(mktemp -t annotation_err_XXXXXX.log)
trap 'rm -f "$ERROR_LOG"' EXIT INT TERM HUP

echo "========================================================"
echo "    SECURE VARIANT ANNOTATION (snpEff) & FILTERING      "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual commands on BOTH success and failure
print_manual_commands() {
    local vcf="${VCF_FILE:-<input.vcf>}"
    local db="${DB_NAME:-<database_name>}"
    local out="${OUT_DIR:-results/annotation}"
    local pref="${PREFIX:-sample}"
    local mem="${MEMORY:-4}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN VARIANT ANNOTATION MANUALLY NEXT TIME:"
    echo "You can bypass this script and annotate directly in the terminal:"
    echo ""
    echo "1. Find your organism's database:"
    echo "   snpEff databases | grep -i \"coli\""
    echo ""
    echo "2. Annotate the VCF file:"
    echo "   snpEff -Xmx${mem}g ${db} ${vcf} > ${out}/${pref}_annotated.vcf"
    echo ""
    echo "3. Filter for HIGH and MODERATE impact mutations (SnpSift):"
    echo "   SnpSift -Xmx${mem}g filter \"( ANN[*].IMPACT = 'HIGH' ) | ( ANN[*].IMPACT = 'MODERATE' )\" ${out}/${pref}_annotated.vcf > ${out}/${pref}_impactful.vcf"
    echo ""
    echo "4. Extract variants into a readable spreadsheet:"
    echo "   SnpSift -Xmx${mem}g extractFields ${out}/${pref}_impactful.vcf CHROM POS REF ALT \"ANN[*].GENE\" \"ANN[*].EFFECT\" \"ANN[*].HGVS_P\" > ${out}/${pref}_report.tsv"
    echo "========================================================"
}

# ========================================================
# 2. DEPENDENCY CHECK
# ========================================================
MISSING_TOOLS=()
for tool in snpEff SnpSift; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if (( ${#MISSING_TOOLS[@]} > 0 )); then
    echo "❌ PIPELINE FAILED: Missing required tools: ${MISSING_TOOLS[*]:-}"
    echo "   Fix: Run 'conda install -c bioconda snpeff snpsift -y'"
    print_manual_commands
    exit 1
fi

# ========================================================
# 3. AUTO-DETECT INPUT VCF FILE
# ========================================================
read -e -p "1. VCF file folder (press [Enter] for current folder or 'results/vcf'): " VCF_DIR
VCF_DIR="${VCF_DIR:-results/vcf}"
VCF_DIR="${VCF_DIR/#\~/$HOME}"
VCF_DIR="${VCF_DIR%/}"

if [[ ! -d "$VCF_DIR" && "$(basename "$PWD")" == "$VCF_DIR" ]]; then
    VCF_DIR="."
fi

if [[ ! -d "$VCF_DIR" ]]; then
    VCF_DIR="."
fi

# Safely find the first VCF file to use as a default
DEFAULT_VCF=$(find "$VCF_DIR" -maxdepth 1 -type f -name "*.vcf" -exec basename {} \; 2>/dev/null | head -n 1)
echo "--------------------------------------------------------"
read -e -p "2. Enter input VCF filename (press [Enter] for '${DEFAULT_VCF:-none}'): " VCF_NAME
VCF_NAME="${VCF_NAME:-$DEFAULT_VCF}"
VCF_FILE="${VCF_DIR}/${VCF_NAME}"

# Absolute path resolution
VCF_FILE=$(readlink -f "$VCF_FILE" 2>/dev/null || realpath "$VCF_FILE" 2>/dev/null || echo "$VCF_FILE")

if [[ ! -f "$VCF_FILE" || ! -s "$VCF_FILE" ]]; then
    echo "❌ PIPELINE FAILED: Input VCF '$VCF_FILE' is missing or empty!"
    print_manual_commands
    exit 1
fi

# ========================================================
# 4. PARAMETERS & DIRECTORY SETUP
# ========================================================
echo "--------------------------------------------------------"
GUESSED_SAMPLE=$(basename "$VCF_FILE" | sed -E 's/(_final)?(_variants)?\.vcf$//')
read -p "3. Enter Sample ID for output prefix (press [Enter] for '$GUESSED_SAMPLE'): " PREFIX
PREFIX="${PREFIX:-$GUESSED_SAMPLE}"
PREFIX=$(echo "$PREFIX" | tr -cd 'A-Za-z0-9_-') # Sanitize against injection

if [[ -z "$PREFIX" ]]; then
    echo "❌ PIPELINE FAILED: Sample ID cannot be empty or invalid."
    exit 1
fi

echo "--------------------------------------------------------"
echo "👉 Enter the exact snpEff database name for your organism."
echo "   (e.g., Escherichia_coli_B_REL606, GRCh38.105, etc.)"
read -p "4. Organism Database Name: " DB_NAME

# SECURITY FIX: Strip malicious bash injection characters from user input
DB_NAME=$(echo "$DB_NAME" | tr -cd 'A-Za-z0-9_.-')

if [[ -z "$DB_NAME" ]]; then
    echo "❌ PIPELINE FAILED: Database name cannot be blank or contain illegal characters."
    echo "   Tip: Use 'snpEff databases | grep \"coli\"' to find the right name."
    print_manual_commands
    exit 1
fi

TOTAL_RAM=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 8)
DEF_RAM=$(( TOTAL_RAM > 6 ? 6 : (TOTAL_RAM > 2 ? TOTAL_RAM - 1 : 2) ))
read -p "5. Max RAM / Memory in GB (Detected ~${TOTAL_RAM}GB total; press [Enter] for ${DEF_RAM}): " MEMORY
MEMORY="${MEMORY:-$DEF_RAM}"

if ! [[ "$MEMORY" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ PIPELINE FAILED: RAM must be a positive whole number."
    exit 1
fi

read -e -p "6. Output folder name (press [Enter] for 'results/annotation'): " OUT_DIR
OUT_DIR="${OUT_DIR:-results/annotation}"
OUT_DIR="${OUT_DIR/#\~/$HOME}"
OUT_DIR="${OUT_DIR%/}"

if ! mkdir -p "$OUT_DIR" 2>/dev/null; then
    echo "❌ PIPELINE FAILED: Could not create output directory '$OUT_DIR'."
    exit 1
fi

OUT_ANN="${OUT_DIR}/${PREFIX}_annotated.vcf"
OUT_IMP="${OUT_DIR}/${PREFIX}_impactful.vcf"
OUT_TSV="${OUT_DIR}/${PREFIX}_report.tsv"

# ========================================================
# 5. SECURE PIPELINE EXECUTION
# ========================================================
echo "========================================================"
echo "✔ Input VCF        : $VCF_FILE"
echo "✔ Database         : $DB_NAME"
echo "✔ Allocated RAM    : ${MEMORY} GB"
echo "✔ Output Directory : $OUT_DIR/"
echo "========================================================"

echo "⏳ Step 1/3: Annotating VCF with snpEff... (This downloads the DB if missing)"
if ! snpEff -Xmx"${MEMORY}g" "$DB_NAME" "$VCF_FILE" > "$OUT_ANN" 2>> "$ERROR_LOG"; then
    echo "❌ FAILED DURING 'snpEff' annotation!"
    echo "   Common issue: Incorrect database name or lack of internet connection."
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi

if [[ ! -s "$OUT_ANN" ]]; then
    echo "❌ PIPELINE FAILED: '$OUT_ANN' was created but is empty."
    print_manual_commands
    exit 1
fi
echo "✔ Saved annotated VCF: $OUT_ANN"

echo ""
echo "⏳ Step 2/3: Filtering for HIGH & MODERATE impact variants (SnpSift)..."
if ! SnpSift -Xmx"${MEMORY}g" filter "( ANN[*].IMPACT = 'HIGH' ) | ( ANN[*].IMPACT = 'MODERATE' )" "$OUT_ANN" > "$OUT_IMP" 2>> "$ERROR_LOG"; then
    echo "❌ FAILED DURING 'SnpSift filter'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved impactful VCF: $OUT_IMP"

echo ""
echo "⏳ Step 3/3: Extracting findings into a readable TSV spreadsheet..."
if ! SnpSift -Xmx"${MEMORY}g" extractFields "$OUT_IMP" CHROM POS REF ALT "ANN[*].GENE" "ANN[*].EFFECT" "ANN[*].HGVS_P" > "$OUT_TSV" 2>> "$ERROR_LOG"; then
    echo "❌ FAILED DURING 'SnpSift extractFields'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved summary spreadsheet: $OUT_TSV"

# ========================================================
# 6. QUALITY STATS & SUMMARY
# ========================================================
echo "========================================================"
echo "✅ PIPELINE SUCCESS! Quick Summary:"
echo "--------------------------------------------------------"

# Use || true to prevent pipefail from crashing the script if grep finds nothing
TOTAL_VARS=$(grep -v "^#" "$VCF_FILE" | wc -l || echo "0")
ANN_VARS=$(grep -v "^#" "$OUT_ANN" | wc -l || echo "0")
IMP_VARS=$(grep -v "^#" "$OUT_IMP" | wc -l || echo "0")

echo "   • Total variants originally called : $TOTAL_VARS"
echo "   • Variants successfully annotated  : $ANN_VARS"
echo "   • HIGH/MODERATE impact mutations   : $IMP_VARS"
echo "--------------------------------------------------------"

if [[ "$IMP_VARS" -gt 0 ]]; then
    echo "🧬 PREVIEW OF TOP 5 IMPACTFUL MUTATIONS:"
    head -n 6 "$OUT_TSV" | column -t -s $'\t' | sed 's/^/   /' || true
else
    echo "   No HIGH or MODERATE impact mutations were found in this sample."
fi

echo "========================================================"

print_manual_commands
