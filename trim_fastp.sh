#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# Enforce strict variable checking and pipe failure detection
set -u
set -o pipefail

# Secure temporary error log with automatic cleanup (prevents orphaned files)
ERROR_LOG=$(mktemp -t trim_err_XXXXXX.log)
trap 'rm -f "$ERROR_LOG"' EXIT INT TERM HUP

echo "========================================================"
echo "    SECURE PAIRED-END TRIMMING (fastp) & QC (FastQC)    "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual commands on BOTH success and failure
print_manual_commands() {
    local fwd="${FWD_READ:-<forward_read.fastq.gz>}"
    local rev="${REV_READ:-<reverse_read.fastq.gz>}"
    local pref="${SAMPLE:-sample}"
    local out="${OUTDIR:-trimmed_data}"
    local t="${THREADS:-4}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN TRIMMING & QC MANUALLY NEXT TIME:"
    echo "You can bypass this script and run the steps directly:"
    echo ""
    echo "1. Run fastp manually (smart defaults):"
    echo "   fastp -i ${fwd} -I ${rev} -o ${out}/${pref}_1_paired.fastq.gz -O ${out}/${pref}_2_paired.fastq.gz -w ${t}"
    echo ""
    echo "2. Run FastQC manually on the trimmed reads:"
    echo "   fastqc -t ${t} -o ${out} ${out}/${pref}_1_paired.fastq.gz ${out}/${pref}_2_paired.fastq.gz"
    echo "========================================================"
}

# ========================================================
# 2. DEPENDENCY CHECK
# ========================================================
# Initialize array properly to prevent set -u unbound variable crashes
MISSING_TOOLS=()
for tool in fastp fastqc; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if (( ${#MISSING_TOOLS[@]} > 0 )); then
    echo "❌ PIPELINE FAILED: Missing required tools: ${MISSING_TOOLS[*]:-}"
    echo "   Fix: Run 'sudo apt update && sudo apt install -y fastp fastqc'"
    print_manual_commands
    exit 1
fi

# ========================================================
# 3. DIRECTORY & INPUT VALIDATION
# ========================================================
read -e -p "1. Data folder path (press [Enter] for current folder): " WORKDIR
WORKDIR="${WORKDIR:-.}"
WORKDIR="${WORKDIR/#\~/$HOME}"
WORKDIR="${WORKDIR%/}"

if [[ ! -d "$WORKDIR" && "$(basename "$PWD")" == "$WORKDIR" ]]; then
    WORKDIR="."
fi

if [[ ! -d "$WORKDIR" ]]; then
    echo "❌ TRIMMING FAILED: Directory '$WORKDIR' does not exist."
    print_manual_commands
    exit 1
fi

cd "$WORKDIR" || exit 1
echo "✔ Using data folder: $(pwd)"
echo "--------------------------------------------------------"

read -e -p "2. Enter the Sample ID or Accession (e.g., SRR957824): " RAW_INPUT

# SECURITY FIX: Strip suffixes and malicious command injection characters
SAMPLE=$(basename "$RAW_INPUT" | sed -E 's/(_R?[12](_001)?(_paired|_unpaired)?)\.(fastq|fq)(\.gz)?$//; s/\.(fastq|fq)(\.gz)?$//')
SAMPLE=$(echo "$SAMPLE" | tr -cd 'A-Za-z0-9_-')

if [[ -z "$SAMPLE" ]]; then
    echo "❌ TRIMMING FAILED: Sample ID cannot be empty or invalid."
    print_manual_commands
    exit 1
fi

# Auto-detect Forward and Reverse read files safely
FWD_READ=""
REV_READ=""
for EXT in "fastq.gz" "fq.gz" "fastq" "fq"; do
    if [[ -f "${SAMPLE}_1.${EXT}" && -f "${SAMPLE}_2.${EXT}" ]]; then
        FWD_READ="${SAMPLE}_1.${EXT}"
        REV_READ="${SAMPLE}_2.${EXT}"
        break
    elif [[ -f "${SAMPLE}_R1.${EXT}" && -f "${SAMPLE}_R2.${EXT}" ]]; then
        FWD_READ="${SAMPLE}_R1.${EXT}"
        REV_READ="${SAMPLE}_R2.${EXT}"
        break
    elif [[ -f "${SAMPLE}_R1_001.${EXT}" && -f "${SAMPLE}_R2_001.${EXT}" ]]; then
        FWD_READ="${SAMPLE}_R1_001.${EXT}"
        REV_READ="${SAMPLE}_R2_001.${EXT}"
        break
    fi
done

if [[ -z "$FWD_READ" || -z "$REV_READ" ]]; then
    echo "❌ TRIMMING FAILED: Could not find paired read files for '$SAMPLE' in $(pwd)"
    print_manual_commands
    exit 1
fi

if [[ ! -s "$FWD_READ" || ! -s "$REV_READ" ]]; then
    echo "❌ TRIMMING FAILED: One or both input FASTQ files are empty (0 bytes)."
    print_manual_commands
    exit 1
fi

# Convert to absolute paths so internal directory switching doesn't break the tools
FWD_READ=$(readlink -f "$FWD_READ" 2>/dev/null || realpath "$FWD_READ" 2>/dev/null || echo "$FWD_READ")
REV_READ=$(readlink -f "$REV_READ" 2>/dev/null || realpath "$REV_READ" 2>/dev/null || echo "$REV_READ")

# ========================================================
# 4. PARAMETERS & DIRECTORY SETUP
# ========================================================
echo "--------------------------------------------------------"
read -e -p "3. Output folder name (press [Enter] for 'trimmed_data'): " OUTDIR
OUTDIR="${OUTDIR:-trimmed_data}"
OUTDIR="${OUTDIR/#\~/$HOME}"
OUTDIR="${OUTDIR%/}"

if ! mkdir -p "$OUTDIR" 2>/dev/null; then
    echo "❌ TRIMMING FAILED: Could not create output folder '$OUTDIR' (Permission denied)."
    print_manual_commands
    exit 1
fi

echo "--------------------------------------------------------"
echo "TRIMMING PARAMETERS (Press [Enter] to use recommended defaults):"
read -p "4. Sliding window size in bases (default: 4): " WIN_SIZE
WIN_SIZE="${WIN_SIZE:-4}"

read -p "5. Minimum Phred quality score to cut at (default: 20): " QUAL_SCORE
QUAL_SCORE="${QUAL_SCORE:-20}"

read -p "6. Minimum read length to keep in bp (default: 36): " MIN_LEN
MIN_LEN="${MIN_LEN:-36}"

read -p "7. Cut bases off the 5' start? (trim_front, press Enter for 0): " HEAD_BASES
HEAD_BASES="${HEAD_BASES:-0}"

read -p "8. Max read length from 3' end? (max_len, press Enter for none): " CROP_LEN

MAX_CORES=$(nproc 2>/dev/null || echo 4)
DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
read -p "9. CPU threads to use (Detected $MAX_CORES cores; default: $DEF_THREADS): " THREADS
THREADS="${THREADS:-$DEF_THREADS}"

if ! [[ "$WIN_SIZE" =~ ^[0-9]+$ && "$QUAL_SCORE" =~ ^[0-9]+$ && "$MIN_LEN" =~ ^[0-9]+$ && "$HEAD_BASES" =~ ^[0-9]+$ && "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ TRIMMING FAILED: Numerical parameters and threads must be positive whole numbers."
    exit 1
fi

# ========================================================
# 5. SECURE PIPELINE EXECUTION (DYNAMIC BASH ARRAYS)
# ========================================================
echo "========================================================"
echo "✔ Forward read     : $FWD_READ"
echo "✔ Reverse read     : $REV_READ"
echo "✔ CPU Threads      : $THREADS"
echo "✔ Output directory : $OUTDIR/"
echo "========================================================"
echo "⏳ Step 1/2: Running fastp trimming..."

# Build the fastp array dynamically based on user inputs
CMD_FASTP=(fastp --thread "$THREADS" -i "$FWD_READ" -I "$REV_READ" 
           -o "${OUTDIR}/${SAMPLE}_1_paired.fastq.gz" 
           -O "${OUTDIR}/${SAMPLE}_2_paired.fastq.gz" 
           --unpaired1 "${OUTDIR}/${SAMPLE}_1_unpaired.fastq.gz" 
           --unpaired2 "${OUTDIR}/${SAMPLE}_2_unpaired.fastq.gz" 
           --detect_adapter_for_pe --cut_right 
           --cut_window_size "$WIN_SIZE" 
           --cut_mean_quality "$QUAL_SCORE" 
           --qualified_quality_phred "$QUAL_SCORE" 
           --length_required "$MIN_LEN" 
           -h "${OUTDIR}/${SAMPLE}_fastp.html" 
           -j "${OUTDIR}/${SAMPLE}_fastp.json")

if [[ "$HEAD_BASES" -gt 0 ]]; then
    CMD_FASTP+=(--trim_front1 "$HEAD_BASES" --trim_front2 "$HEAD_BASES")
fi

if [[ -n "$CROP_LEN" ]]; then
    if [[ "$CROP_LEN" =~ ^[0-9]+$ && "$CROP_LEN" -gt 0 ]]; then
        CMD_FASTP+=(--max_len1 "$CROP_LEN" --max_len2 "$CROP_LEN")
    fi
fi

if ! "${CMD_FASTP[@]}" 2> >(tee -a "$ERROR_LOG" >&2); then
    echo "❌ FAILED DURING 'fastp'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved trimmed reads and fastp QC report."

echo ""
echo "⏳ Step 2/2: Running FastQC on trimmed reads..."
CMD_FASTQC=(fastqc -t "$THREADS" -o "$OUTDIR" "${OUTDIR}/${SAMPLE}_1_paired.fastq.gz" "${OUTDIR}/${SAMPLE}_2_paired.fastq.gz")

if ! "${CMD_FASTQC[@]}" 2> >(tee -a "$ERROR_LOG" >&2); then
    echo "❌ FAILED DURING 'fastqc'!"
    cat "$ERROR_LOG"
    print_manual_commands
    exit 1
fi
echo "✔ Saved FastQC HTML reports."

# ========================================================
# 6. OPTIONAL CLEANUP & SUMMARY
# ========================================================
echo "========================================================"
echo "✅ PIPELINE SUCCESS! File cleanup options:"
echo "   • ${SAMPLE}_*_unpaired.fastq.gz (orphan reads)"
echo "   • ${SAMPLE}_fastp.json          (raw machine log for MultiQC)"
echo "   • ${SAMPLE}_*_fastqc.zip        (bulky data files for FastQC)"
read -p "10. Do you want to REMOVE these optional files to save space? [y/N]: " CLEANUP_CHOICE

if [[ "$CLEANUP_CHOICE" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    rm -f "${OUTDIR}/${SAMPLE}_1_unpaired.fastq.gz" \
          "${OUTDIR}/${SAMPLE}_2_unpaired.fastq.gz" \
          "${OUTDIR}/${SAMPLE}_fastp.json" \
          "${OUTDIR}/${SAMPLE}_1_paired_fastqc.zip" \
          "${OUTDIR}/${SAMPLE}_2_paired_fastqc.zip"
    echo "🗑  Removed orphan reads, fastp JSON, and FastQC ZIP files."
else
    echo "📁 Kept all intermediate files."
fi

echo "--------------------------------------------------------"
echo "Your final saved files in $(pwd)/${OUTDIR}/:"
ls -lh "${OUTDIR}/${SAMPLE}"*
echo "========================================================"

print_manual_commands
