#!/bin/bash

echo "========================================================"
echo "     UNIVERSAL QUAST GENOME ASSEMBLY EVALUATION         "
echo "========================================================"
echo "📍 Current directory: $(pwd)"
echo "👉 Tip: Press [Enter] at any prompt to use the default,"
echo "   or press [Tab] to auto-complete folder/file paths!"
echo "--------------------------------------------------------"

# Helper function to print manual QUAST commands on BOTH success and failure
print_manual_commands() {
    local files_str="${ASSEMBLY_FILES[*]:-spades_out/contigs.fasta}"
    local out="${OUTDIR:-quast_results}"
    local t="${THREADS:-4}"
    local mc="${MIN_CONTIG:-500}"
    local ref="${REF_FILE:-~/data/ecoli_ref_genome/ecoli_ref.fasta}"

    echo ""
    echo "========================================================"
    echo "💡 HOW TO RUN QUAST MANUALLY NEXT TIME:"
    echo "You can run QUAST directly in the terminal anytime using"
    echo "either of these simple one-line commands:"
    echo ""
    echo "1. Ultra-short manual command (without reference genome):"
    echo "   quast.py ${files_str} -o ${out}"
    echo ""
    if [[ -n "$REF_FILE" ]]; then
        echo "2. Manual command WITH your reference genome & settings:"
        echo "   quast.py ${files_str} -r ${REF_FILE} -m ${mc} -t ${t} -o ${out}"
    else
        echo "2. Manual command WITH a reference genome & custom settings:"
        echo "   quast.py ${files_str} -r ${ref} -m ${mc} -t ${t} -o ${out}"
    fi
    echo "========================================================"
}

# 1. Check if QUAST is installed and working
if command -v quast.py &> /dev/null; then
    QUAST_CMD="quast.py"
elif command -v quast &> /dev/null; then
    QUAST_CMD="quast"
else
    echo "❌ QUAST FAILED: 'quast.py' is not installed or not in your PATH."
    echo "   Fix: Activate your quast environment first:"
    echo "        conda activate quastenv"
    print_manual_commands
    exit 1
fi

# Verify QUAST doesn't crash on Python 3.13 missing 'distutils'
if ! "$QUAST_CMD" --version &> /dev/null; then
    echo "❌ QUAST FAILED: '$QUAST_CMD' is installed but crashed (likely Python 3.13 'distutils' error)."
    echo "   Fix: Run 'conda install -c conda-forge -c bioconda python=3.10 quast setuptools -y'"
    print_manual_commands
    exit 1
fi

# ========================================================
# 2. ASK FOR THE FOLDER CONTAINING ASSEMBLY DATA
# ========================================================
# Auto-detect if a SPAdes output folder exists in the current directory
DEFAULT_ASM_DIR="."
DETECTED_SPADES=$(find . -maxdepth 1 -type d -name "*spades*" 2>/dev/null | head -n 1 | sed 's|^\./||')
if [[ -n "$DETECTED_SPADES" ]]; then
    DEFAULT_ASM_DIR="$DETECTED_SPADES"
fi

echo "👉 Press [Enter] below to use '$DEFAULT_ASM_DIR', or type the folder path"
echo "   where your assembled FASTA files are stored."
read -e -p "1. Assembly data folder path (press [Enter] for '$DEFAULT_ASM_DIR'): " DATA_DIR
DATA_DIR="${DATA_DIR:-$DEFAULT_ASM_DIR}"
DATA_DIR="${DATA_DIR/#\~/$HOME}"
DATA_DIR="${DATA_DIR%/}"

# If user typed the name of the folder they are ALREADY standing in, stay here
if [[ ! -d "$DATA_DIR" && "$(basename "$PWD")" == "$DATA_DIR" ]]; then
    DATA_DIR="."
fi

if [[ ! -d "$DATA_DIR" ]]; then
    echo "❌ QUAST FAILED: Directory '$DATA_DIR' does not exist!"
    echo "   Current working directory: $(pwd)"
    print_manual_commands
    exit 1
fi

echo "✔ Using assembly folder: $DATA_DIR"
echo "--------------------------------------------------------"

# ========================================================
# 3. LIST AVAILABLE FILES & ASK USER WHICH FILE(S) TO USE
# ========================================================
echo "📂 Assembly FASTA files found inside '$DATA_DIR':"
AVAILABLE_FASTA=$(ls "$DATA_DIR" 2>/dev/null | grep -E '\.(fasta|fa|fna)(\.gz)?$')

if [[ -n "$AVAILABLE_FASTA" ]]; then
    echo "$AVAILABLE_FASTA" | sed 's/^/   • /'
else
    echo "   (No .fasta, .fa, or .fna files detected in '$DATA_DIR')"
fi

# Choose smart default file (prefer contigs.fasta if present)
DEFAULT_FILE=""
if [[ -f "${DATA_DIR}/contigs.fasta" ]]; then
    DEFAULT_FILE="contigs.fasta"
elif [[ -n "$AVAILABLE_FASTA" ]]; then
    DEFAULT_FILE=$(echo "$AVAILABLE_FASTA" | head -n 1)
fi

echo ""
echo "👉 You can enter one file (e.g., contigs.fasta) or multiple space-separated"
echo "   files (e.g., contigs.fasta scaffolds.fasta) to compare them side-by-side."
read -e -p "2. Enter file(s) to run QUAST on (press [Enter] for '${DEFAULT_FILE:-contigs.fasta}'): " RAW_FILES
RAW_FILES="${RAW_FILES:-$DEFAULT_FILE}"

if [[ -z "$RAW_FILES" ]]; then
    echo "❌ QUAST FAILED: You did not specify any assembly files."
    print_manual_commands
    exit 1
fi

# Validate each file entered by the user
ASSEMBLY_FILES=()
for ITEM in $RAW_FILES; do
    ITEM="${ITEM/#\~/$HOME}"
    if [[ -f "$ITEM" ]]; then
        TARGET_FILE="$ITEM"
    elif [[ -f "${DATA_DIR}/${ITEM}" ]]; then
        TARGET_FILE="${DATA_DIR}/${ITEM}"
    elif [[ -f "${DATA_DIR}/$(basename "$ITEM")" ]]; then
        TARGET_FILE="${DATA_DIR}/$(basename "$ITEM")"
    else
        echo "❌ QUAST FAILED: Assembly file '$ITEM' could not be found in '$DATA_DIR'!"
        print_manual_commands
        exit 1
    fi

    if [[ ! -s "$TARGET_FILE" ]]; then
        echo "❌ QUAST FAILED: Assembly file '$TARGET_FILE' is empty (0 bytes)!"
        print_manual_commands
        exit 1
    fi
    ASSEMBLY_FILES+=("$TARGET_FILE")
done

echo "✔ Selected assembly file(s): ${ASSEMBLY_FILES[*]}"
echo "--------------------------------------------------------"

# ========================================================
# 4. OPTIONAL REFERENCE GENOME COMPARISON
# ========================================================
REF_FLAGS=()
REF_FILE=""

read -p "3. Do you want to compare your assembly to a reference genome? [y/N]: " USE_REF
if [[ "$USE_REF" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo "👉 Enter the folder or full file path of your reference genome"
    echo "   (e.g., ~/data/ecoli_ref_genome or ~/data/ecoli_ref_genome/ecoli_ref.fasta)"
    read -e -p "4. Reference genome path (press [Enter] for current folder): " REF_INPUT
    REF_INPUT="${REF_INPUT:-.}"
    REF_INPUT="${REF_INPUT/#\~/$HOME}"
    REF_INPUT="${REF_INPUT%/}"

    if [[ ! -e "$REF_INPUT" && "$(basename "$PWD")" == "$REF_INPUT" ]]; then
        REF_INPUT="."
    fi

    # If the user entered a directory, list FASTA files inside and ask which one
    if [[ -d "$REF_INPUT" ]]; then
        DEFAULT_REF=$(ls "$REF_INPUT" 2>/dev/null | grep -E '\.(fasta|fa|fna)(\.gz)?$' | head -n 1)
        echo "   Reference FASTA files found in '$REF_INPUT':"
        if [[ -n "$DEFAULT_REF" ]]; then
            ls "$REF_INPUT" | grep -E '\.(fasta|fa|fna)(\.gz)?$' | sed 's/^/     • /'
        else
            echo "     (No .fasta, .fa, or .fna files found in '$REF_INPUT')"
        fi
        read -e -p "   Enter reference filename (press [Enter] for '${DEFAULT_REF:-none}'): " REF_NAME
        REF_NAME="${REF_NAME:-$DEFAULT_REF}"
        REF_FILE="${REF_INPUT}/$(basename "$REF_NAME")"
    elif [[ -f "$REF_INPUT" ]]; then
        REF_FILE="$REF_INPUT"
    else
        echo "❌ QUAST FAILED: Reference path '$REF_INPUT' does not exist!"
        print_manual_commands
        exit 1
    fi

    if [[ -z "$REF_FILE" || ! -f "$REF_FILE" ]]; then
        echo "❌ QUAST FAILED: Reference genome file '$REF_FILE' is missing!"
        print_manual_commands
        exit 1
    elif [[ ! -s "$REF_FILE" ]]; then
        echo "❌ QUAST FAILED: Reference genome file '$REF_FILE' is empty (0 bytes)!"
        print_manual_commands
        exit 1
    fi

    REF_FLAGS=(-r "$REF_FILE")
    echo "✔ Using Reference Genome: $REF_FILE"
else
    echo "✔ Running QUAST without a reference genome (de novo assessment)."
fi

# ========================================================
# 5. OUTPUT FOLDER & QUAST PARAMETERS (SMART DEFAULTS)
# ========================================================
echo "--------------------------------------------------------"
echo "QUAST PARAMETERS (Press [Enter] to use recommended defaults):"
read -e -p "5. Output folder name (press [Enter] for 'quast_results'): " OUTDIR
OUTDIR="${OUTDIR:-quast_results}"
OUTDIR="${OUTDIR/#\~/$HOME}"
OUTDIR="${OUTDIR%/}"

read -p "6. Minimum contig length in bp to evaluate (default: 500): " MIN_CONTIG
MIN_CONTIG="${MIN_CONTIG:-500}"

MAX_CORES=$(nproc 2>/dev/null || echo 4)
DEF_THREADS=$(( MAX_CORES > 4 ? 4 : MAX_CORES ))
read -p "7. CPU threads to use (Detected $MAX_CORES cores; default: $DEF_THREADS): " THREADS
THREADS="${THREADS:-$DEF_THREADS}"

if ! [[ "$MIN_CONTIG" =~ ^[0-9]+$ && "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ QUAST FAILED: Minimum contig length and CPU threads must be positive whole numbers."
    print_manual_commands
    exit 1
fi

# ========================================================
# 6. RUN QUAST & DISPLAY SUMMARY REPORT
# ========================================================
echo "========================================================"
echo "✔ Assembly File(s) : ${ASSEMBLY_FILES[*]}"
echo "✔ Reference Genome : ${REF_FILE:-None (De Novo Mode)}"
echo "✔ Min Contig Length: ${MIN_CONTIG} bp"
echo "✔ CPU Threads      : ${THREADS}"
echo "✔ Output Directory : ${OUTDIR}/"
echo "========================================================"
echo "⏳ Running QUAST now... Please wait."
echo ""

ERROR_LOG=$(mktemp)

if "$QUAST_CMD" "${ASSEMBLY_FILES[@]}" \
    "${REF_FLAGS[@]}" \
    --min-contig "$MIN_CONTIG" \
    --threads "$THREADS" \
    -o "$OUTDIR" 2> >(tee "$ERROR_LOG" >&2); then

    if [[ ! -s "${OUTDIR}/report.txt" ]]; then
        echo ""
        echo "❌ QUAST FAILED: QUAST finished, but '${OUTDIR}/report.txt' was not created!"
        print_manual_commands
        rm -f "$ERROR_LOG"
        exit 1
    fi

    echo ""
    echo "✅ SUCCESS! QUAST evaluation completed without errors."
    echo "========================================================"
    echo "📊 QUAST SUMMARY TABLE (${OUTDIR}/report.txt):"
    echo "--------------------------------------------------------"
    cat "${OUTDIR}/report.txt"
    echo "========================================================"

    # ========================================================
    # 7. LIST ALL GENERATED FILES & ASK ONE-AT-A-TIME CLEANUP
    # ========================================================
    echo ""
    echo "📂 ALL FILES AND FOLDERS PRODUCED BY QUAST IN '${OUTDIR}/':"
    ls -1 "$OUTDIR" | sed 's/^/   • /'
    echo "--------------------------------------------------------"
    echo "🔒 Essential files automatically KEPT for you:"
    echo "   ✔ report.html (Interactive visual graphs & charts)"
    echo "   ✔ report.txt  (Summary table printed above)"
    echo "--------------------------------------------------------"

    read -p "8. Do you want to review the other QUAST files/folders ONE AT A TIME to choose what to keep or delete? [Y/n]: " REVIEW_ONE_BY_ONE
    REVIEW_ONE_BY_ONE="${REVIEW_ONE_BY_ONE:-y}"

    if [[ "$REVIEW_ONE_BY_ONE" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo ""
        echo "👉 For each item below, type 'y' to KEEP it, or 'n' (or press [Enter]) to DELETE it:"
        for ITEM_PATH in "${OUTDIR}"/*; do
            ITEM_NAME=$(basename "$ITEM_PATH")

            # Always protect report.html and report.txt
            if [[ "$ITEM_NAME" == "report.html" || "$ITEM_NAME" == "report.txt" ]]; then
                continue
            fi

            # Describe what each common QUAST output item is
            DESC="Additional QUAST output"
            case "$ITEM_NAME" in
                icarus.html|icarus_viewers) DESC="Interactive contig alignment browser (needed if opening Icarus links)" ;;
                report.pdf)                 DESC="PDF version of all QUAST plots and tables" ;;
                report.tsv|report.tex)      DESC="Spreadsheet/LaTeX versions of the summary table" ;;
                transposed_report.*)        DESC="Rotated versions of the summary report (rows/columns swapped)" ;;
                basic_stats)                DESC="Folder of raw GC content and contig length plots" ;;
                aligned_stats)              DESC="Folder of reference alignment metrics (NA50, NGA50)" ;;
                contigs_reports)            DESC="Folder of detailed misassembly and unaligned contig logs" ;;
                quast.log)                  DESC="Technical execution log file" ;;
            esac

            echo ""
            if [[ -d "$ITEM_PATH" ]]; then
                echo "📁 Folder: $ITEM_NAME  — ($DESC)"
            else
                echo "📄 File  : $ITEM_NAME  — ($DESC)"
            fi

            read -p "   Keep '$ITEM_NAME'? [y/N] (press [Enter] to delete, 'y' to keep): " KEEP_ITEM
            if [[ "$KEEP_ITEM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                echo "   ✔ Kept '$ITEM_NAME'"
            else
                rm -rf "$ITEM_PATH"
                echo "   🗑️  Deleted '$ITEM_NAME'"
            fi
        done
    else
        echo "📁 Kept all QUAST output files and folders."
    fi

    echo "--------------------------------------------------------"
    echo "✅ Final saved files in $(pwd)/${OUTDIR}/:"
    ls -lh "$OUTDIR"

    # Always display manual commands
    print_manual_commands
    rm -f "$ERROR_LOG"
else
    echo ""
    echo "❌ QUAST EXECUTION FAILED!"
    cat "$ERROR_LOG"
    rm -f "$ERROR_LOG"

    # Still display manual commands even if execution fails
    print_manual_commands
    exit 1
fi
