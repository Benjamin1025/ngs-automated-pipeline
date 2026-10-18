#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# Prevent accidental execution of unset variables
set -u 

# Secure temporary file creation and automatic cleanup (prevents orphaned files if you press Ctrl+C)
ERROR_LOG=$(mktemp -t prokka_err_XXXXXX.log)
trap 'rm -f "$ERROR_LOG"' EXIT INT TERM HUP

echo "========================================================"
echo "      SECURE PROKKA GENOME ANNOTATION PIPELINE          "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual Prokka commands on BOTH success and failure
print_manual_commands() {
    local fa="${FASTA_FILE:-contigs.fasta}"
    local out="${OUTDIR:-prokka_annotation}"
    local pref="${PREFIX:-sample}"
    local t="${THREADS:-4}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN PROKKA MANUALLY NEXT TIME:"
    echo "You can run Prokka directly in the terminal anytime using"
    echo "either of these simple one-line commands:"
    echo ""
    echo "1. Ultra-short manual command (Basic annotation):"
    echo "   prokka --outdir ${out} --prefix ${pref} --force ${fa}"
    echo ""
    echo "2. Recommended manual command with your chosen settings:"
    echo "   prokka --outdir ${out} --prefix ${pref} --cpus ${t} --force ${META_MANUAL:-} ${fa}"
    echo "========================================================"
}

# ========================================================
# 2. DEPENDENCY CHECK
# ========================================================
if ! command -v prokka &> /dev/null; then
    echo "❌ ANNOTATION FAILED: 'prokka' is not installed or not in your PATH."
    echo "   Fix: Activate your prokka environment first:"
    echo "        conda activate prokka_env"
    print_manual_commands
    exit 1
fi

# ========================================================
# 3. AUTO-DETECT & VALIDATE ASSEMBLED FASTA FILE
# ========================================================
DEFAULT_FASTA=""
DETECTED_CONTIGS=$(find . -maxdepth 2 -type f -name "contigs.fasta" 2>/dev/null | head -n 1 | sed 's|^\./||')

if [[ -n "$DETECTED_CONTIGS" ]]; then
    DEFAULT_FASTA="$DETECTED_CONTIGS"
else
    DEFAULT_FASTA=$(ls *.fasta *.fa *.fna 2>/dev/null | head -n 1)
fi

read -e -p "1. Assembled FASTA file (press [Enter] for '${DEFAULT_FASTA:-none}'): " FASTA_INPUT
FASTA_FILE="${FASTA_INPUT:-$DEFAULT_FASTA}"
FASTA_FILE="${FASTA_FILE/#\~/$HOME}"

if [[ -z "$FASTA_FILE" || ! -f "$FASTA_FILE" ]]; then
    echo "❌ ANNOTATION FAILED: Assembly file '$FASTA_FILE' could not be found!"
    print_manual_commands
    exit 1
elif [[ ! -s "$FASTA_FILE" ]]; then
    echo "❌ ANNOTATION FAILED: Assembly file '$FASTA_FILE' is empty (0 bytes)!"
    print_manual_commands
    exit 1
fi

# Convert FASTA_FILE to absolute path to prevent relative path breakage
FASTA_FILE=$(readlink -f "$FASTA_FILE" 2>/dev/null || realpath "$FASTA_FILE" 2>/dev/null || echo "$FASTA_FILE")
echo "✔ Using genome assembly: $FASTA_FILE"
echo "--------------------------------------------------------"

# ========================================================
# 4. SAMPLE ID & OUTPUT DIRECTORY (WITH SANITIZATION)
# ========================================================
GUESSED_SAMPLE=$(basename "$(dirname "$FASTA_FILE")" | sed 's/_spades_out//; s/_assembly//')
if [[ "$GUESSED_SAMPLE" == "." || -z "$GUESSED_SAMPLE" ]]; then
    GUESSED_SAMPLE=$(basename "$FASTA_FILE" | sed -E 's/\.(fasta|fa|fna)$//')
fi

read -p "2. Enter Sample ID for file prefixes (press [Enter] for '$GUESSED_SAMPLE'): " PREFIX
PREFIX="${PREFIX:-$GUESSED_SAMPLE}"

# SECURITY FIX: Strip malicious command injection characters (e.g., ; & | $ >) from the prefix
PREFIX=$(echo "$PREFIX" | tr -cd 'A-Za-z0-9_-')

if [[ -z "$PREFIX" ]]; then
    echo "❌ ANNOTATION FAILED: Prefix cannot be empty after removing invalid characters."
    exit 1
fi

read -e -p "3. Enter output folder name (press [Enter] for '${PREFIX}_prokka'): " OUTDIR
OUTDIR="${OUTDIR:-${PREFIX}_prokka}"
OUTDIR="${OUTDIR/#\~/$HOME}"
OUTDIR="${OUTDIR%/}"

FORCE_FLAG=()
if [[ -d "$OUTDIR" ]]; then
    echo "⚠️  Folder '$OUTDIR' already exists!"
    read -p "   Do you want to overwrite it? [Y/n]: " OVERWRITE
    OVERWRITE="${OVERWRITE:-y}"
    if [[ "$OVERWRITE" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        FORCE_FLAG=(--force)
        echo "   ✔ Will overwrite existing folder (--force)."
    else
        echo "❌ ANNOTATION CANCELLED: Please run again and choose a new output folder."
        exit 1
    fi
fi

# ========================================================
# 5. ORGANISM METADATA & SYSTEM RESOURCES
# ========================================================
echo "--------------------------------------------------------"
echo "🧬 BIOLOGICAL METADATA (Improves annotation accuracy):"
read -p "4. Do you want to specify the organism (e.g., Escherichia coli)? [Y/n]: " ADD_META
ADD_META="${ADD_META:-y}"

META_FLAGS=()
META_MANUAL=""

if [[ "$ADD_META" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    read -p "   Genus (press [Enter] for 'Escherichia'): " ORG_GENUS
    ORG_GENUS="${ORG_GENUS:-Escherichia}"
    # SECURITY FIX: Quote variables to handle multi-word species/strains cleanly
    
    read -p "   Species (press [Enter] for 'coli'): " ORG_SPECIES
    ORG_SPECIES="${ORG_SPECIES:-coli}"
    
    read -p "   Strain (press [Enter] for '$PREFIX'): " ORG_STRAIN
    ORG_STRAIN="${ORG_STRAIN:-$PREFIX}"
    
    META_FLAGS+=(--kingdom Bacteria --genus "$ORG_GENUS" --species "$ORG_SPECIES" --strain "$ORG_STRAIN" --usegenus)
    # Manual command string representation
    META_MANUAL="--kingdom Bacteria --genus '${ORG_GENUS}' --species '${ORG_SPECIES}' --usegenus"
else
    echo "   ✔ Skipping specific organism metadata (Defaulting to general Bacteria)."
fi

echo "--------------------------------------------------------"
MAX_CORES=$(nproc 2>/dev/null || echo 4)
DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
read -p "5. CPU threads to use (Detected $MAX_CORES cores; default: $DEF_THREADS): " THREADS
THREADS="${THREADS:-$DEF_THREADS}"

# SECURITY FIX: Strict regex validation ensuring threads is a positive integer
if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ ANNOTATION FAILED: CPU threads must be a positive whole number."
    exit 1
fi

# ========================================================
# 6. RUN PROKKA SECURELY USING BASH ARRAYS
# ========================================================
echo "========================================================"
echo "✔ Assembly File    : $FASTA_FILE"
echo "✔ File Prefix      : $PREFIX"
if [[ -n "$META_MANUAL" ]]; then
    echo "✔ Organism         : $ORG_GENUS $ORG_SPECIES ($ORG_STRAIN)"
fi
echo "✔ CPU Threads      : $THREADS"
echo "✔ Output Directory : $OUTDIR/"
echo "========================================================"
echo "⏳ Running Prokka annotation now... (Usually takes 2-5 mins)"
echo ""

# SECURITY FIX: Execute command via Bash Array to prevent word-splitting and globbing attacks
PROKKA_CMD=(prokka --outdir "$OUTDIR" --prefix "$PREFIX" --cpus "$THREADS" "${FORCE_FLAG[@]}" "${META_FLAGS[@]}" "$FASTA_FILE")

if "${PROKKA_CMD[@]}" 2> >(tee "$ERROR_LOG" >&2); then
    if [[ ! -s "${OUTDIR}/${PREFIX}.txt" ]]; then
        echo ""
        echo "❌ ANNOTATION FAILED: Prokka finished, but '${OUTDIR}/${PREFIX}.txt' was not created!"
        print_manual_commands
        exit 1
    fi

    echo ""
    echo "✅ SUCCESS! Genome annotation completed without errors."
    echo "========================================================"
    echo "📊 ANNOTATION SUMMARY (${OUTDIR}/${PREFIX}.txt):"
    echo "--------------------------------------------------------"
    sed 's/^/   /' "${OUTDIR}/${PREFIX}.txt"
    echo "--------------------------------------------------------"
    echo "🧬 FIRST 10 DETECTED GENES (${PREFIX}.tsv):"
    head -n 11 "${OUTDIR}/${PREFIX}.tsv" | column -t -s $'\t' | sed 's/^/   /'
    echo "========================================================"

    echo ""
    echo "📂 MAIN FILES SAVED IN $(pwd)/${OUTDIR}/:"
    echo "   • ${PREFIX}.gff : Master annotation file (Open this in IGV or use for Roary)"
    echo "   • ${PREFIX}.gbk : GenBank file (Open this in Artemis or SnapGene)"
    echo "   • ${PREFIX}.faa : Protein FASTA (All translated amino acid sequences)"
    echo "   • ${PREFIX}.ffn : Gene FASTA (All nucleotide gene sequences)"
    echo "   • ${PREFIX}.tsv : Searchable spreadsheet of all genes"

    print_manual_commands
else
    echo ""
    echo "❌ PROKKA EXECUTION FAILED!"
    echo "   Check the error log below for details."
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
