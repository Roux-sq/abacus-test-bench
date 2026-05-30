#!/bin/bash
# run_all.sh — Run all solvers on all example cases and produce a summary CSV.
#
# Usage:
#   ./run_all.sh --np 4 --solvers cg,bpcg,ppcg           # all 10 cases
#   ./run_all.sh --np 4 --solvers cg,bpcg,ppcg --quick   # first 3 cases only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_COMPARE="$SCRIPT_DIR/run_compare.sh"

# ── defaults ────────────────────────────────────────────────────────────────
SOLVERS="cg,bpcg,ppcg"
NP=""
DEVICE="auto"
BINARY=""
OUTPUT_DIR="$SCRIPT_DIR/results"
QUICK=0
EXAMPLES_ROOT="$(cd "$SCRIPT_DIR/../../abacus-user-guide/examples/pw" 2>/dev/null && pwd)"
if [[ -z "$EXAMPLES_ROOT" || ! -d "$EXAMPLES_ROOT" ]]; then
    EXAMPLES_ROOT=""
fi

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --solvers)
            SOLVERS="$2"; shift 2 ;;
        --solvers=*)
            SOLVERS="${1#--solvers=}"; shift ;;
        --np)
            NP="$2"; shift 2 ;;
        --np=*)
            NP="${1#--np=}"; shift ;;
        --quick)
            QUICK=1; shift ;;
        --device)
            DEVICE="$2"; shift 2 ;;
        --device=*)
            DEVICE="${1#--device=}"; shift ;;
        --binary)
            BINARY="$2"; shift 2 ;;
        --binary=*)
            BINARY="${1#--binary=}"; shift ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)
            OUTPUT_DIR="${1#--output-dir=}"; shift ;;
        --examples-root)
            EXAMPLES_ROOT="$2"; shift 2 ;;
        --examples-root=*)
            EXAMPLES_ROOT="${1#--examples-root=}"; shift ;;
        -h|--help)
            echo "Usage: $0 --np N [--solvers LIST] [--quick] [--device DEV] [--binary PATH]"
            echo ""
            echo "Options:"
            echo "  --solvers LIST    Comma-separated solver list (default: cg,bpcg,ppcg)"
            echo "  --np N            Number of MPI processes (required)"
            echo "  --quick           Only run first 3 examples (quick validation)"
            echo "  --device DEV      Device: cpu, gpu, or auto (default: auto)"
            echo "  --binary PATH     Path to ABACUS binary"
            echo "  --output-dir DIR  Directory for results (default: ./results)"
            echo "  --examples-root   Root directory for pw examples (auto-detected)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── validate ────────────────────────────────────────────────────────────────
if [[ -z "$NP" ]]; then
    echo "ERROR: --np is required" >&2; exit 1
fi
if [[ -z "$EXAMPLES_ROOT" || ! -d "$EXAMPLES_ROOT" ]]; then
    echo "ERROR: cannot find examples directory." >&2
    echo "  Expected: ../../abacus-user-guide/examples/pw/" >&2
    echo "  Use --examples-root to specify the path." >&2
    exit 1
fi

# Build binary path if not specified
if [[ -z "$BINARY" ]]; then
    BINARY="$(cd "$SCRIPT_DIR/../../abacus-develop/build" 2>/dev/null && pwd)/abacus"
    if [[ ! -f "$BINARY" ]]; then
        echo "ERROR: ABACUS binary not found." >&2
        echo "  Tried: $BINARY" >&2
        echo "  Use --binary to specify the path, or build ABACUS first." >&2
        exit 1
    fi
fi

mkdir -p "$OUTPUT_DIR/logs"
SUMMARY_CSV="$OUTPUT_DIR/summary.csv"

# ── discover examples ───────────────────────────────────────────────────────
mapfile -t EXAMPLES < <(find "$EXAMPLES_ROOT" -maxdepth 1 -type d -name '[0-9]*' | sort)
if [[ ${#EXAMPLES[@]} -eq 0 ]]; then
    echo "ERROR: no example directories found under $EXAMPLES_ROOT" >&2
    exit 1
fi

if [[ "$QUICK" -eq 1 ]]; then
    EXAMPLES=("${EXAMPLES[@]:0:3}")
    echo "=== Quick mode: running first 3 examples ==="
fi

echo "=== ABACUS Multi-Solver Benchmark ==="
echo "Examples root: $EXAMPLES_ROOT"
echo "Solvers:       $SOLVERS"
echo "Device:        $DEVICE"
echo "MPI procs:     $NP"
echo "Binary:        $BINARY"
echo "Examples:      ${#EXAMPLES[@]} cases"
echo "Quick mode:    $([[ $QUICK -eq 1 ]] && echo yes || echo no)"
echo ""

# Build run_compare extra args
RC_EXTRA=()
[[ -n "$BINARY" ]] && RC_EXTRA+=(--binary "$BINARY")
RC_EXTRA+=(--device "$DEVICE")
RC_EXTRA+=(--output-dir "$OUTPUT_DIR")

# ── initialize summary CSV ──────────────────────────────────────────────────
echo "example,solver,device,atoms,np,total_energy,scf_steps,wall_time_s,exit_code,ppcg_info" > "$SUMMARY_CSV"

# ── run each example ────────────────────────────────────────────────────────
TOTAL_START=$(date +%s)
PASS_COUNT=0
FAIL_COUNT=0
FAIL_LIST=""

for i in "${!EXAMPLES[@]}"; do
    example_dir="${EXAMPLES[$i]}"
    example_name="$(basename "$example_dir")"

    # Count atoms from STRU for context
    ATOMS="?"
    if [[ -f "$example_dir/STRU" ]]; then
        ATOMS=$(grep -c 'ATOM' "$example_dir/STRU" 2>/dev/null || echo "?")
        # Adjust: ATOMIC_SPECIES section is one, try to count actual atom lines
        ATOMS=$(grep -E '^[[:space:]]*[0-9]+\.[0-9]+[[:space:]]' "$example_dir/STRU" 2>/dev/null | wc -l || echo "?")
    fi

    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  [$((i+1))/${#EXAMPLES[@]}] $example_name (atoms=$ATOMS)"
    echo "╚══════════════════════════════════════════════════════════════════════╝"

    CASE_START=$(date +%s)

    set +e
    bash "$RUN_COMPARE" \
        --solvers "$SOLVERS" \
        --np "$NP" \
        --example "$example_dir" \
        "${RC_EXTRA[@]}"
    CASE_EXIT=$?
    set -e

    CASE_END=$(date +%s)
    CASE_TIME=$((CASE_END - CASE_START))

    # Read per-case results and append to summary
    RESULT_FILE="$OUTPUT_DIR/results_${example_name}.csv"
    if [[ -f "$RESULT_FILE" ]]; then
        # Skip header line, append each data line (avoid pipe subshell for counter)
        while IFS= read -r line; do
            # Extract solver and device from the line
            read_solver=$(echo "$line" | cut -d',' -f1)
            read_device=$(echo "$line" | cut -d',' -f2)
            ppcg_info=""
            if [[ "$read_solver" == "ppcg" ]]; then
                # PPCG: solver,device,np,energy,steps,time,code,iters,locked → fields 8,9
                ppcg_iters=$(echo "$line" | cut -d',' -f8 2>/dev/null || echo "")
                ppcg_locked=$(echo "$line" | cut -d',' -f9 2>/dev/null || echo "")
                ppcg_info="iters=$ppcg_iters locked=$ppcg_locked"
            fi
            echo "$example_name,$read_solver,$read_device,$ATOMS,$(echo "$line" | cut -d',' -f3-),$ppcg_info"
        done < <(tail -n +2 "$RESULT_FILE") >> "$SUMMARY_CSV"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        # Run may have failed completely
        IFS=',' read -ra SOLVER_ARRAY <<< "$SOLVERS"
        for solver in "${SOLVER_ARRAY[@]}"; do
            solver=$(echo "$solver" | xargs)
            echo "$example_name,$solver,$DEVICE,$ATOMS,$NP,FAIL,FAIL,FAIL,FAIL," >> "$SUMMARY_CSV"
        done
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_LIST="$FAIL_LIST $example_name"
    fi

    echo "  Case time: ${CASE_TIME}s"
    echo ""
done

TOTAL_END=$(date +%s)
TOTAL_TIME=$((TOTAL_END - TOTAL_START))

# ── final summary ───────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Final Summary"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Total time:    ${TOTAL_TIME}s ($((TOTAL_TIME / 60)) min)"
echo "Cases passed:  $PASS_COUNT"
echo "Cases failed:  $FAIL_COUNT"
if [[ -n "$FAIL_LIST" ]]; then
    echo "Failed cases: $FAIL_LIST"
fi
echo ""
echo "Summary CSV:   $SUMMARY_CSV"
echo ""

# Print the summary CSV as a quick overview
if [[ -f "$SUMMARY_CSV" ]]; then
    echo "--- Summary Table ---"
    column -t -s ',' "$SUMMARY_CSV" | sed 's/^/  /'
    echo ""
fi

echo "=== Done ==="
