#!/bin/bash
# run_compare.sh — Run multiple solvers on a single example case and compare results.
#
# Usage:
#   ./run_compare.sh --solvers cg,bpcg,ppcg,dav,dav_subspace --np 4 \
#       --example ../../abacus-user-guide/examples/pw/001_4GaAs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SINGLE="$SCRIPT_DIR/run_single.sh"

# ── defaults ────────────────────────────────────────────────────────────────
SOLVERS="cg,bpcg,ppcg,dav,dav_subspace"
NP=""
EXAMPLE_DIR=""
BINARY=""
OUTPUT_DIR="$SCRIPT_DIR/results"

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
        --example)
            EXAMPLE_DIR="$2"; shift 2 ;;
        --example=*)
            EXAMPLE_DIR="${1#--example=}"; shift ;;
        --binary)
            BINARY="$2"; shift 2 ;;
        --binary=*)
            BINARY="${1#--binary=}"; shift ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)
            OUTPUT_DIR="${1#--output-dir=}"; shift ;;
        -h|--help)
            echo "Usage: $0 --np N --example DIR [--solvers LIST] [--binary PATH]"
            echo ""
            echo "Options:"
            echo "  --solvers LIST  Comma-separated solver list (default: cg,bpcg,ppcg,dav,dav_subspace)"
            echo "  --np N          Number of MPI processes (required)"
            echo "  --example DIR   Path to example directory (required)"
            echo "  --binary PATH   Path to ABACUS binary"
            echo "  --output-dir DIR Directory for results (default: ./results)"
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
if [[ -z "$EXAMPLE_DIR" ]]; then
    echo "ERROR: --example is required" >&2; exit 1
fi
if [[ ! -d "$EXAMPLE_DIR" ]]; then
    echo "ERROR: example directory not found: $EXAMPLE_DIR" >&2; exit 1
fi

EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"
EXAMPLE_NAME="$(basename "$EXAMPLE_DIR")"

# Build binary path if not specified
if [[ -z "$BINARY" ]]; then
    BINARY="$(cd "$SCRIPT_DIR/../../abacus-develop/build" 2>/dev/null && pwd)/abacus"
fi

# Build run_single extra args
RS_EXTRA=()
[[ -n "$BINARY" ]] && RS_EXTRA+=(--binary "$BINARY")
RS_EXTRA+=(--output-dir "$OUTPUT_DIR")

# ── print header ────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  ABACUS Solver Comparison: $EXAMPLE_NAME"
echo "║  Solvers: $SOLVERS"
echo "║  MPI processes: $NP"
echo "║  Binary: ${BINARY:-auto-detect}"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── run each solver ─────────────────────────────────────────────────────────
RESULTS=()
SOLVER_EXIT_CODES=()

IFS=',' read -ra SOLVER_ARRAY <<< "$SOLVERS"
for solver in "${SOLVER_ARRAY[@]}"; do
    solver=$(echo "$solver" | xargs)  # trim whitespace
    echo "──────────────────────────────────────────────────────────────────────"
    echo "  Running: $solver"
    echo "──────────────────────────────────────────────────────────────────────"

    set +e
    bash "$RUN_SINGLE" \
        --solver "$solver" \
        --np "$NP" \
        --example "$EXAMPLE_DIR" \
        "${RS_EXTRA[@]}" \
        2>&1 | sed 's/^/  /'
    EXIT_CODE=${PIPESTATUS[0]}
    set -e

    SOLVER_EXIT_CODES+=("$solver:$EXIT_CODE")
    echo ""
done

# ── summarize ────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  Comparison Summary: $EXAMPLE_NAME"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# Read all result CSVs for this example
RESULT_FILE="$OUTPUT_DIR/results_${EXAMPLE_NAME}.csv"
if [[ -f "$RESULT_FILE" ]]; then
    echo "  Raw data: $RESULT_FILE"
    echo ""
    # Print as a formatted table
    column -t -s ',' "$RESULT_FILE" | sed 's/^/  /'
else
    echo "  No results file found."
fi

echo ""

# Check exit codes
echo "  Exit status:"
for entry in "${SOLVER_EXIT_CODES[@]}"; do
    IFS=':' read -r solver code <<< "$entry"
    if [[ "$code" -eq 0 ]]; then
        echo "    $solver: PASS"
    else
        echo "    $solver: FAIL (exit=$code)"
    fi
done

echo ""
echo "  Log files: $OUTPUT_DIR/logs/${EXAMPLE_NAME}_*.log"
echo "  Error files: $OUTPUT_DIR/logs/${EXAMPLE_NAME}_*.err"
