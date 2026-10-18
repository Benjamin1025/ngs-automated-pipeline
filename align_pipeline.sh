#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# Enforce strict variable checking to prevent silent crashes
set -u

# Secure temporary error log with automatic cleanup (prevents orphaned files)
BWA_ERR=$(mktemp -t bwa_err_XXXXXX.log)
trap 'rm -f "$BWA_ERR"' EXIT INT TERM HUP

echo "========================================================"
echo " UNIVERSAL SECURE BWA & SAMTOOLS ALIGNMENT PIPELINE     "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any folder prompt if the files are"
echo "   already in your current directory, or use [Tab] to auto-complete!"
echo "--------------------------------------------------------"

# Helper function to print manual commands on BOTH success and failure
print_manual_commands() {
    local ref="${REF_FILE:-<reference_genome.fasta>}"
    local fwd="${FWD_READ:-<forward_read.fastq.gz>}"
    local rev="${REV_READ:-<reverse_read.fastq.gz>}"
    local bam="${BAM_PATH:-<aligned_sorted.bam>}"
    local t="${THREADS:-4}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN THIS ALIGNMENT MANUALLY NEXT TIME:"
    echo "You can bypass this script and align directly in the terminal"
    echo "using this optimized, one-line piped command:"
    echo ""
    echo "1. Index the reference (Only needed once per genome):"
    echo "   bwa index ${ref}"
    echo ""
    echo "2. Align, sort, index, and calculate stats in one go:"
    echo "   bwa mem -t ${t} ${ref} ${fwd} ${rev} | samtools sort -@ ${t} -o ${bam} && samtools index -@ ${t} ${bam} && samtools flagstat -@ ${t} ${bam}"
    echo "========================================================"
}

# 2. Check if BWA and SAMtools are installed
if ! command -v bwa &> /dev/null; then
    echo "❌ ALIGNMENT FAILED: 'bwa' is not installed."
    echo "   Fix: Run 'sudo apt update && sudo apt install -y bwa'"
    print_manual_commands
    exit 1
fi

if ! command -v samtools &> /dev/null; then
    echo "❌ ALIGNMENT FAILED: 'samtools' is not installed."
    echo "   Fix: Run 'sudo apt update && sudo apt install -y samtools'"
    print_manual_commands
    exit 1
fi

# ========================================================
# 3. REFERENCE GENOME & AUTOMATIC INDEX CHECK
# ========================================================
read -e -p "1. Reference genome folder (press [Enter] for current folder): " REF_DIR
REF_DIR="${REF_DIR:-.}"
REF_DIR="${REF_DIR/#\~/$HOME}"
REF_DIR="${REF_DIR%/}"

if [[ ! -d "$REF_DIR" && "$(basename "$PWD")" == "$REF_DIR" ]]; then
    REF_DIR="."
fi

if [[ ! -d "$REF_DIR" ]]; then
    echo "❌ ALIGNMENT FAILED: Reference directory '$REF_DIR' does not exist!"
    print_manual_commands
    exit 1
fi

DEFAULT_REF=$(ls "$REF_DIR" 2>/dev/null | grep -E '\.(fasta|fa|fna)$' | head -n 1)

echo "   FASTA files found in $REF_DIR:"
if [[ -n "$DEFAULT_REF" ]]; then
    ls "$REF_DIR" | grep -E '\.(fasta|fa|fna)$' | sed 's/^/     - /'
else
    echo "     (No .fasta, .fa, or .fna files found in $REF_DIR)"
fi

read -e -p "2. Enter reference genome filename (press [Enter] for '${DEFAULT_REF:-none}'): " REF_NAME
REF_NAME="${REF_NAME:-$DEFAULT_REF}"
REF_NAME=$(basename "$REF_NAME")
REF_FILE="${REF_DIR}/${REF_NAME}"

# Absolute path resolution for safety
REF_FILE=$(readlink -f "$REF_FILE" 2>/dev/null || realpath "$REF_FILE" 2>/dev/null || echo "$REF_FILE")

if [[ -z "$REF_NAME" || ! -f "$REF_FILE" ]]; then
    echo "❌ ALIGNMENT FAILED: Reference genome file '$REF_FILE' is missing!"
    print_manual_commands
    exit 1
elif [[ ! -s "$REF_FILE" ]]; then
    echo "❌ ALIGNMENT FAILED: Reference file '$REF_FILE' is empty (0 bytes)!"
    print_manual_commands
    exit 1
fi

echo "--------------------------------------------------------"
if [[ -f "${REF_FILE}.amb" && -f "${REF_FILE}.ann" && -f "${REF_FILE}.bwt" && -f "${REF_FILE}.pac" && -f "${REF_FILE}.sa" ]]; then
    echo "✔ BWA index files already exist for '$REF_NAME'. Skipping indexing step!"
else
    echo "⚙ BWA index files not found. Indexing '$REF_FILE' now..."
    if ! bwa index "$REF_FILE"; then
        echo "❌ ALIGNMENT FAILED: 'bwa index' encountered an error while indexing '$REF_FILE'."
        print_manual_commands
        exit 1
    fi
    echo "✔ Indexing completed successfully!"
fi
echo "--------------------------------------------------------"

# ========================================================
# 4. CHOOSE TRIMMED VS. UNTRIMMED READS & INPUT DIRECTORY
# ========================================================
echo "Which type of FASTQ reads do you want to align?"
echo "  [1] Trimmed reads (e.g., SAMPLE_1_paired.fastq.gz & SAMPLE_2_paired.fastq.gz)"
echo "  [2] Untrimmed raw reads (e.g., SAMPLE_1.fastq.gz & SAMPLE_2.fastq.gz)"
read -p "Select 1 or 2 (press [Enter] for 1): " READ_TYPE
READ_TYPE="${READ_TYPE:-1}"

if [[ "$READ_TYPE" != "1" && "$READ_TYPE" != "2" ]]; then
    echo "❌ ALIGNMENT FAILED: Invalid selection '$READ_TYPE'. Please enter 1 or 2."
    print_manual_commands
    exit 1
fi

read -e -p "3. Folder containing FASTQ files (press [Enter] for current folder): " READ_DIR
READ_DIR="${READ_DIR:-.}"
READ_DIR="${READ_DIR/#\~/$HOME}"
READ_DIR="${READ_DIR%/}"

if [[ ! -d "$READ_DIR" && "$(basename "$PWD")" == "$READ_DIR" ]]; then
    READ_DIR="."
fi

if [[ ! -d "$READ_DIR" ]]; then
    echo "❌ ALIGNMENT FAILED: Read directory '$READ_DIR' does not exist!"
    print_manual_commands
    exit 1
fi

read -e -p "4. Enter the Sample ID or Accession (e.g., SRR957824): " RAW_SAMPLE
SAMPLE=$(basename "$RAW_SAMPLE" | sed -E 's/(_R?[12](_001)?(_paired|_unpaired)?)\.(fastq|fq)(\.gz)?$//; s/\.(fastq|fq)(\.gz)?$//')

# SECURITY FIX: Strip malicious command injection characters
SAMPLE=$(echo "$SAMPLE" | tr -cd 'A-Za-z0-9_-')

if [[ -z "$SAMPLE" ]]; then
    echo "❌ ALIGNMENT FAILED: Sample ID cannot be empty or invalid."
    print_manual_commands
    exit 1
fi

# Auto-detect Forward and Reverse read files
FWD_READ=""
REV_READ=""
for EXT in "fastq.gz" "fq.gz" "fastq" "fq"; do
    if [[ "$READ_TYPE" == "1" ]]; then
        if [[ -f "${READ_DIR}/${SAMPLE}_1_paired.${EXT}" && -f "${READ_DIR}/${SAMPLE}_2_paired.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_1_paired.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_2_paired.${EXT}"
            break
        elif [[ -f "${READ_DIR}/${SAMPLE}_R1_paired.${EXT}" && -f "${READ_DIR}/${SAMPLE}_R2_paired.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_R1_paired.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_R2_paired.${EXT}"
            break
        fi
    else
        if [[ -f "${READ_DIR}/${SAMPLE}_1.${EXT}" && -f "${READ_DIR}/${SAMPLE}_2.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_1.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_2.${EXT}"
            break
        elif [[ -f "${READ_DIR}/${SAMPLE}_R1.${EXT}" && -f "${READ_DIR}/${SAMPLE}_R2.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_R1.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_R2.${EXT}"
            break
        elif [[ -f "${READ_DIR}/${SAMPLE}_R1_001.${EXT}" && -f "${READ_DIR}/${SAMPLE}_R2_001.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_R1_001.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_R2_001.${EXT}"
            break
        fi
    fi
done

if [[ -z "$FWD_READ" || -z "$REV_READ" ]]; then
    echo "❌ ALIGNMENT FAILED: Could not find matching paired FASTQ files for '$SAMPLE' in '$READ_DIR'."
    print_manual_commands
    exit 1
fi

if [[ ! -s "$FWD_READ" || ! -s "$REV_READ" ]]; then
    echo "❌ ALIGNMENT FAILED: One or both input FASTQ files are empty (0 bytes)!"
    print_manual_commands
    exit 1
fi

# Convert read files to absolute paths to prevent failures if relative paths are altered
FWD_READ=$(readlink -f "$FWD_READ" 2>/dev/null || realpath "$FWD_READ" 2>/dev/null || echo "$FWD_READ")
REV_READ=$(readlink -f "$REV_READ" 2>/dev/null || realpath "$REV_READ" 2>/dev/null || echo "$REV_READ")

# ========================================================
# 5. HARDWARE CONFIGURATION & OUTPUT DIRECTORIES
# ========================================================
echo "--------------------------------------------------------"
MAX_CORES=$(nproc 2>/dev/null || echo 4)
DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
read -p "5. CPU threads to use (Detected $MAX_CORES cores; default: $DEF_THREADS): " THREADS
THREADS="${THREADS:-$DEF_THREADS}"

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ ALIGNMENT FAILED: Threads must be a positive whole number."
    exit 1
fi

read -e -p "6. Folder to save output .sam file (press [Enter] for 'aligned_data'): " SAM_DIR
SAM_DIR="${SAM_DIR:-aligned_data}"
SAM_DIR="${SAM_DIR/#\~/$HOME}"
SAM_DIR="${SAM_DIR%/}"

if ! mkdir -p "$SAM_DIR" 2>/dev/null; then
    echo "❌ ALIGNMENT FAILED: Could not create directory '$SAM_DIR' (Permission denied)."
    print_manual_commands
    exit 1
fi

read -p "7. Name for your .sam file (press [Enter] for '${SAMPLE}.sam'): " SAM_NAME
SAM_NAME="${SAM_NAME:-${SAMPLE}.sam}"
# Sanitize output filename
SAM_NAME=$(echo "$SAM_NAME" | tr -cd 'A-Za-z0-9_.-')
[[ "$SAM_NAME" != *.sam ]] && SAM_NAME="${SAM_NAME}.sam"
SAM_PATH="${SAM_DIR}/${SAM_NAME}"

read -e -p "8. Folder to save sorted .bam files (press [Enter] to also use '$SAM_DIR'): " BAM_DIR
BAM_DIR="${BAM_DIR:-$SAM_DIR}"
BAM_DIR="${BAM_DIR/#\~/$HOME}"
BAM_DIR="${BAM_DIR%/}"

if ! mkdir -p "$BAM_DIR" 2>/dev/null; then
    echo "❌ ALIGNMENT FAILED: Could not create directory '$BAM_DIR' (Permission denied)."
    print_manual_commands
    exit 1
fi

DEFAULT_BAM="${SAM_NAME%.sam}_sorted.bam"
read -p "9. Name for your sorted .bam file (press [Enter] for '$DEFAULT_BAM'): " BAM_NAME
BAM_NAME="${BAM_NAME:-$DEFAULT_BAM}"
BAM_NAME=$(echo "$BAM_NAME" | tr -cd 'A-Za-z0-9_.-')
[[ "$BAM_NAME" != *.bam ]] && BAM_NAME="${BAM_NAME}.bam"
BAM_PATH="${BAM_DIR}/${BAM_NAME}"

# ========================================================
# 6. RUN BWA MEM ALIGNMENT
# ========================================================
echo "========================================================"
echo "✔ Reference Genome : $REF_FILE"
echo "✔ Forward Read     : $FWD_READ"
echo "✔ Reverse Read     : $REV_READ"
echo "✔ CPU Threads      : $THREADS"
echo "✔ Output SAM File  : $SAM_PATH"
echo "✔ Output BAM File  : $BAM_PATH"
echo "========================================================"
echo "⏳ Step 1/4: Running 'bwa mem' alignment..."

# Run BWA directly executing binary variables to prevent string execution bypass
if ! bwa mem -t "$THREADS" "$REF_FILE" "$FWD_READ" "$REV_READ" > "$SAM_PATH" 2> >(tee "$BWA_ERR" >&2); then
    echo "❌ ALIGNMENT FAILED DURING 'bwa mem'!"
    cat "$BWA_ERR"
    print_manual_commands
    exit 1
fi

if [[ ! -s "$SAM_PATH" ]]; then
    echo "❌ ALIGNMENT FAILED: '$SAM_PATH' was created but is empty (0 bytes)!"
    print_manual_commands
    exit 1
fi
echo "✔ Step 1/4 Complete: SAM file saved to $SAM_PATH"

# ========================================================
# 7. RUN SAMTOOLS (SORT, INDEX, FLAGSTAT)
# ========================================================
echo ""
echo "⏳ Step 2/4: Converting SAM to coordinate-sorted BAM ('samtools sort')..."
if ! samtools sort -@ "$THREADS" -o "$BAM_PATH" "$SAM_PATH"; then
    echo "❌ FAILED DURING 'samtools sort'!"
    print_manual_commands
    exit 1
fi
echo "✔ Step 2/4 Complete: Sorted BAM saved to $BAM_PATH"

echo ""
echo "⏳ Step 3/4: Indexing sorted BAM file ('samtools index')..."
if ! samtools index -@ "$THREADS" "$BAM_PATH"; then
    echo "❌ FAILED DURING 'samtools index'!"
    print_manual_commands
    exit 1
fi
echo "✔ Step 3/4 Complete: BAM index saved to ${BAM_PATH}.bai"

echo ""
echo "⏳ Step 4/4: Calculating alignment statistics ('samtools flagstat')..."
STATS_FILE="${BAM_PATH%.bam}_flagstat.txt"
echo "--------------------------------------------------------"
if ! samtools flagstat -@ "$THREADS" "$BAM_PATH" | tee "$STATS_FILE"; then
    echo "❌ FAILED DURING 'samtools flagstat'!"
    print_manual_commands
    exit 1
fi
echo "--------------------------------------------------------"
echo "✔ Step 4/4 Complete: Alignment stats saved to $STATS_FILE"

# ========================================================
# 8. OPTIONAL CLEANUP OF RAW .SAM FILE
# ========================================================
echo ""
echo "🧹 OPTIONAL FILE CLEANUP:"
echo "   • $SAM_PATH (large uncompressed raw alignment file)"
read -p "10. Do you want to REMOVE '$SAM_PATH' and keep only the compressed sorted BAM files? [y/N]: " DEL_SAM
if [[ "$DEL_SAM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    rm -f "$SAM_PATH"
    echo "🗑️  Removed '$SAM_PATH'."
else
    echo "📁 Kept '$SAM_PATH'."
fi

echo ""
echo "✅ ALL STEPS COMPLETED SUCCESSFULLY!"
echo "Your saved alignment files:"
ls -lh "$BAM_PATH" "${BAM_PATH}.bai" "$STATS_FILE"

# Always print manual commands on successful completion
print_manual_commands
