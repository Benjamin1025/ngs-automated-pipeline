#!/bin/bash

# ========================================================
# 1. ROBUSTNESS & SECURITY CONFIGURATION
# ========================================================
# Enforce strict variable checking and prevent hidden pipe errors
set -u
set -o pipefail

# Secure temporary error log with automatic cleanup (prevents orphaned files)
ERROR_LOG=$(mktemp -t spades_err_XXXXXX.log)
trap 'rm -f "$ERROR_LOG"' EXIT INT TERM HUP

echo "========================================================"
echo "         SECURE SPAdes GENOME ASSEMBLY PIPELINE         "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual commands on BOTH success and failure
print_manual_commands() {
    # Securely fallback to defaults if variables haven't been assigned yet
    local f1="${FWD_READ:-trimmed_data/SRR957824_1_paired.fastq.gz}"
    local f2="${REV_READ:-trimmed_data/SRR957824_2_paired.fastq.gz}"
    local out="${OUTDIR:-spades_out}"
    local t="${THREADS:-4}"
    local m="${MEMORY:-6}"
    local mode="${MODE_FLAG:---isolate}"
    local kmer="${KMER_MANUAL:-}"
    local cov="${COV_MANUAL:-}"
    local unp="${UNPAIRED_MANUAL:-}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN SPAdes MANUALLY NEXT TIME:"
    echo "You can bypass this script and assemble directly in the terminal:"
    echo ""
    echo "1. Run SPAdes manually with your chosen settings:"
    echo "   spades.py ${mode} -t ${t} -m ${m}${kmer}${cov}${unp} -1 ${f1} -2 ${f2} -o ${out}"
    echo ""
    echo "2. Resume an interrupted SPAdes assembly from where it stopped:"
    echo "   spades.py --continue -o ${out}"
    echo "========================================================"
}

# ========================================================
# 2. DEPENDENCY CHECK
# ========================================================
MISSING_TOOLS=()
if ! command -v spades.py &> /dev/null && ! command -v spades &> /dev/null; then
    MISSING_TOOLS+=("spades.py")
fi

# Safe array length check under set -u
if (( ${#MISSING_TOOLS[@]} > 0 )); then
    echo "❌ ASSEMBLY FAILED: Missing required tool: ${MISSING_TOOLS[*]}"
    echo "   Fix: Run 'conda install -c bioconda spades -y' or 'sudo apt install spades'"
    print_manual_commands
    exit 1
fi

SPADES_CMD=$(command -v spades.py || command -v spades)

# ========================================================
# 3. SELECT DATA DIRECTORY & READ TYPE
# ========================================================
echo "Which type of FASTQ reads do you want to assemble?"
echo "  [1] Trimmed reads (Recommended: SAMPLE_1_paired.fastq.gz & SAMPLE_2_paired.fastq.gz)"
echo "  [2] Untrimmed raw reads (SAMPLE_1.fastq.gz & SAMPLE_2.fastq.gz)"
read -p "Select 1 or 2 (press [Enter] for 1): " READ_TYPE
READ_TYPE="${READ_TYPE:-1}"

if [[ "$READ_TYPE" != "1" && "$READ_TYPE" != "2" ]]; then
    echo "❌ ASSEMBLY FAILED: Invalid selection '$READ_TYPE'."
    exit 1
fi

DEFAULT_DIR="."
if [[ "$READ_TYPE" == "1" && -d "trimmed_data" ]]; then
    DEFAULT_DIR="trimmed_data"
fi

echo "--------------------------------------------------------"
read -e -p "1. FASTQ folder path (press [Enter] for '$DEFAULT_DIR'): " READ_DIR
READ_DIR="${READ_DIR:-$DEFAULT_DIR}"
READ_DIR="${READ_DIR/#\~/$HOME}"
READ_DIR="${READ_DIR%/}"

if [[ ! -d "$READ_DIR" && "$(basename "$PWD")" == "$READ_DIR" ]]; then
    READ_DIR="."
fi

if [[ ! -d "$READ_DIR" ]]; then
    echo "❌ ASSEMBLY FAILED: Directory '$READ_DIR' does not exist!"
    exit 1
fi

echo "✔ Looking for reads in: $READ_DIR"
echo "--------------------------------------------------------"

# ========================================================
# 4. SAMPLE ID & AUTO-DETECT READS
# ========================================================
read -e -p "2. Enter Sample ID or Accession (e.g., SRR957824): " RAW_SAMPLE

# SECURITY FIX: Sanitize the sample ID against command injection
SAMPLE=$(basename "$RAW_SAMPLE" | sed -E 's/(_R?[12](_001)?(_paired|_unpaired)?)\.(fastq|fq)(\.gz)?$//; s/\.(fastq|fq)(\.gz)?$//')
SAMPLE=$(echo "$SAMPLE" | tr -cd 'A-Za-z0-9_-')

if [[ -z "$SAMPLE" ]]; then
    echo "❌ ASSEMBLY FAILED: Sample ID cannot be empty or invalid."
    exit 1
fi

FWD_READ=""
REV_READ=""
UNP_READ=""

for EXT in "fastq.gz" "fq.gz" "fastq" "fq"; do
    if [[ "$READ_TYPE" == "1" ]]; then
        if [[ -f "${READ_DIR}/${SAMPLE}_1_paired.${EXT}" && -f "${READ_DIR}/${SAMPLE}_2_paired.${EXT}" ]]; then
            FWD_READ="${READ_DIR}/${SAMPLE}_1_paired.${EXT}"
            REV_READ="${READ_DIR}/${SAMPLE}_2_paired.${EXT}"
            [[ -s "${READ_DIR}/${SAMPLE}_1_unpaired.${EXT}" ]] && UNP_READ="${READ_DIR}/${SAMPLE}_1_unpaired.${EXT}"
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
    echo "❌ ASSEMBLY FAILED: Could not find paired FASTQ files for '$SAMPLE' in '$READ_DIR'."
    exit 1
fi

if [[ ! -s "$FWD_READ" || ! -s "$REV_READ" ]]; then
    echo "❌ ASSEMBLY FAILED: One or both input FASTQ files are empty (0 bytes)!"
    exit 1
fi

# Convert to absolute paths
FWD_READ=$(readlink -f "$FWD_READ" 2>/dev/null || realpath "$FWD_READ" 2>/dev/null || echo "$FWD_READ")
REV_READ=$(readlink -f "$REV_READ" 2>/dev/null || realpath "$REV_READ" 2>/dev/null || echo "$REV_READ")
[[ -n "$UNP_READ" ]] && UNP_READ=$(readlink -f "$UNP_READ" 2>/dev/null || realpath "$UNP_READ" 2>/dev/null || echo "$UNP_READ")

# Ask if user wants to include unpaired reads
UNPAIRED_FLAGS=()
UNPAIRED_MANUAL=""
if [[ -n "$UNP_READ" ]]; then
    read -p "   Found unpaired read file ($(basename "$UNP_READ")). Include it in assembly? [y/N]: " USE_UNP
    if [[ "$USE_UNP" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        UNPAIRED_FLAGS+=(-s "$UNP_READ")
        UNPAIRED_MANUAL=" -s ${UNP_READ}"
    fi
fi

# ========================================================
# 5. OUTPUT DIRECTORY & RESUME/OVERWRITE CHECK
# ========================================================
read -e -p "3. Enter output folder name (press [Enter] for '${SAMPLE}_spades_out'): " OUTDIR
OUTDIR="${OUTDIR:-${SAMPLE}_spades_out}"
OUTDIR="${OUTDIR/#\~/$HOME}"
OUTDIR="${OUTDIR%/}"

RESUME_MODE="no"
if [[ -d "$OUTDIR" && -f "${OUTDIR}/params.txt" ]]; then
    echo "⚠️  Existing SPAdes output folder '$OUTDIR' detected!"
    echo "   [1] Start fresh (deletes old '$OUTDIR' folder and runs from scratch)"
    echo "   [2] Continue interrupted run (spades.py --continue -o $OUTDIR)"
    read -p "   Select 1 or 2 (press [Enter] for 1): " EXIST_CHOICE
    EXIST_CHOICE="${EXIST_CHOICE:-1}"
    if [[ "$EXIST_CHOICE" == "2" ]]; then
        RESUME_MODE="yes"
    else
        rm -rf "$OUTDIR"
    fi
fi

# ========================================================
# 6. SPAdes PARAMETERS (WITH SMART DEFAULTS)
# ========================================================
# Initialize variables to prevent unbound errors
MODE_FLAG=""
MODE_FLAGS=()
KMER_MANUAL=""
KMER_FLAGS=()
COV_MANUAL=""
COV_FLAGS=()

if [[ "$RESUME_MODE" == "no" ]]; then
    echo "--------------------------------------------------------"
    echo "SPAdes ASSEMBLY PARAMETERS (Press [Enter] for defaults):"

    echo "4. Choose SPAdes running mode:"
    echo "   [1] --isolate  (Default: Faster, best for high-coverage isolates)"
    echo "   [2] --careful  (Minimizes mismatches/indels; slower)"
    echo "   [3] Standard   (Default SPAdes with no special mode flag)"
    echo "   [4] --meta     (Metagenomic samples)"
    echo "   [5] --plasmid  (Assemble only plasmids)"
    read -p "   Select mode 1-5 (press [Enter] for 1): " MODE_CHOICE
    MODE_CHOICE="${MODE_CHOICE:-1}"

    case "$MODE_CHOICE" in
        1) MODE_FLAGS+=(--isolate); MODE_FLAG="--isolate" ;;
        2) MODE_FLAGS+=(--careful); MODE_FLAG="--careful" ;;
        3) MODE_FLAG="" ;;
        4) MODE_FLAGS+=(--meta); MODE_FLAG="--meta" ;;
        5) MODE_FLAGS+=(--plasmid); MODE_FLAG="--plasmid" ;;
        *) echo "❌ Invalid mode choice '$MODE_CHOICE'."; exit 1 ;;
    esac

    read -p "5. K-mer sizes (press [Enter] for 'auto', or type e.g. 21,33,55,77): " KMERS
    KMERS="${KMERS:-auto}"
    if [[ "$KMERS" != "auto" ]]; then
        if ! [[ "$KMERS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            echo "❌ ASSEMBLY FAILED: K-mers must be comma-separated odd numbers."
            exit 1
        fi
        KMER_FLAGS+=(-k "$KMERS")
        KMER_MANUAL=" -k ${KMERS}"
    fi

    read -p "6. Coverage cutoff (press [Enter] for 'off', or type 'auto' or a number): " COV_CUT
    COV_CUT="${COV_CUT:-off}"
    if [[ "$COV_CUT" != "off" ]]; then
        COV_FLAGS+=(--cov-cutoff "$COV_CUT")
        COV_MANUAL=" --cov-cutoff ${COV_CUT}"
    fi

    MAX_CORES=$(nproc 2>/dev/null || echo 4)
    DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
    TOTAL_RAM=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}' || echo 8)
    DEF_RAM=$(( TOTAL_RAM > 6 ? 6 : (TOTAL_RAM > 2 ? TOTAL_RAM - 1 : 2) ))

    read -p "7. CPU threads to use (Detected $MAX_CORES cores; press [Enter] for $DEF_THREADS): " THREADS
    THREADS="${THREADS:-$DEF_THREADS}"

    read -p "8. Max RAM / Memory in GB (Detected ~${TOTAL_RAM}GB total; press [Enter] for ${DEF_RAM}): " MEMORY
    MEMORY="${MEMORY:-$DEF_RAM}"

    if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ && "$MEMORY" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ ASSEMBLY FAILED: Threads and Max RAM must be positive whole numbers."
        exit 1
    fi
fi

# ========================================================
# 7. RUN SPAdes (SECURE BASH ARRAY EXECUTION)
# ========================================================
echo "========================================================"
echo "✔ Sample ID        : $SAMPLE"
echo "✔ Forward Read     : $FWD_READ"
echo "✔ Reverse Read     : $REV_READ"
echo "✔ Assembly Mode    : ${MODE_FLAG:-Standard}"
echo "✔ Resources        : ${THREADS:-4} Threads | ${MEMORY:-6} GB Max RAM"
echo "✔ Output Directory : $OUTDIR/"
echo "========================================================"
echo "⏳ Running SPAdes genome assembly... (Takes 10-25 mins)"

# Build the execution array
if [[ "$RESUME_MODE" == "yes" ]]; then
    CMD_SPADES=("$SPADES_CMD" --continue -o "$OUTDIR")
else
    CMD_SPADES=("$SPADES_CMD" "${MODE_FLAGS[@]}" -t "$THREADS" -m "$MEMORY" "${KMER_FLAGS[@]}" "${COV_FLAGS[@]}" -1 "$FWD_READ" -2 "$REV_READ" "${UNPAIRED_FLAGS[@]}" -o "$OUTDIR")
fi

# Execute array securely
if ! "${CMD_SPADES[@]}" 2> >(tee -a "$ERROR_LOG" >&2); then
    echo "❌ SPAdes ASSEMBLY FAILED DURING EXECUTION!"
    echo "   Check '${OUTDIR}/spades.log' for details."
    grep -i -E "Error|Exception|Memory" "$ERROR_LOG" | tail -n 10 || true
    print_manual_commands
    exit 1
fi

if [[ ! -s "${OUTDIR}/contigs.fasta" ]]; then
    echo "❌ ASSEMBLY FAILED: SPAdes finished, but '${OUTDIR}/contigs.fasta' is missing!"
    print_manual_commands
    exit 1
fi

# ========================================================
# 8. OPTIONAL CLEANUP & SUMMARY
# ========================================================
echo ""
echo "========================================================"
echo "✅ PIPELINE SUCCESS! Quick Stats:"
echo "--------------------------------------------------------"
TOTAL_CONTIGS=$(grep -c "^>" "${OUTDIR}/contigs.fasta" || echo "0")
echo "   • Total contigs assembled: $TOTAL_CONTIGS"
echo "   • Top 5 longest contigs (Name_Length_Coverage):"
grep "^>" "${OUTDIR}/contigs.fasta" | head -n 5 | sed 's/^/       /' || true
echo "--------------------------------------------------------"

echo "🧹 OPTIONAL DISK SPACE CLEANUP:"
read -p "9. Do you want to REMOVE SPAdes temporary K-mer/tmp folders to save space? [y/N]: " CLEAN_SPADES
if [[ "$CLEAN_SPADES" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    rm -rf "${OUTDIR}"/K[0-9]* "${OUTDIR}/tmp" "${OUTDIR}/corrected" "${OUTDIR}/misc"
    echo "🗑️  Removed temporary intermediate folders."
fi

echo "--------------------------------------------------------"
echo "Your main files are saved in $(pwd)/${OUTDIR}/:"
ls -lh "${OUTDIR}/contigs.fasta" "${OUTDIR}/scaffolds.fasta" "${OUTDIR}/spades.log" 2>/dev/null || true

print_manual_commands
