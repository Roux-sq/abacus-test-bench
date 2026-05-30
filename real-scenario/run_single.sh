#!/bin/bash
# run_single.sh — Run ABACUS with a specific solver on a single example case.
#
# Usage:
#   ./run_single.sh --solver ppcg --np 4 \
#       --example ../../abacus-user-guide/examples/pw/001_4GaAs \
#       --binary ../../abacus-develop/build/abacus

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────────────
SOLVER=""
NP=""
EXAMPLE_DIR=""
_DEFAULT_BINARY_DIR="$(cd "$(dirname "$0")/../../abacus-develop/build" 2>/dev/null && pwd)" || true
BINARY="${_DEFAULT_BINARY_DIR:-/not/found}/abacus"
OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
OUTPUT_DIR="$(cd "$(dirname "$0")" && pwd)/results"
DRY_RUN=0
TIMEOUT_SEC=3600  # 1 hour per case max

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --solver)
            SOLVER="$2"; shift 2 ;;
        --solver=*)
            SOLVER="${1#--solver=}"; shift ;;
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
        --omp)
            OMP_NUM_THREADS="$2"; shift 2 ;;
        --omp=*)
            OMP_NUM_THREADS="${1#--omp=}"; shift ;;
        --output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*)
            OUTPUT_DIR="${1#--output-dir=}"; shift ;;
        --timeout)
            TIMEOUT_SEC="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            echo "Usage: $0 --solver NAME --np N --example DIR [--binary PATH] [--omp N] [--output-dir DIR]"
            echo ""
            echo "Options:"
            echo "  --solver NAME    Solver to use: cg, bpcg, ppcg, dav, dav_subspace"
            echo "  --np N           Number of MPI processes"
            echo "  --example DIR    Path to example directory (containing INPUT, STRU, KPT)"
            echo "  --binary PATH    Path to ABACUS binary (default: ../../abacus-develop/build/abacus)"
            echo "  --omp N          OpenMP threads (default: 1)"
            echo "  --output-dir DIR Directory for results (default: ./results)"
            echo "  --timeout SEC    Timeout in seconds (default: 3600)"
            echo "  --dry-run        Print what would be done without executing"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── validate args ───────────────────────────────────────────────────────────
if [[ -z "$SOLVER" ]]; then
    echo "ERROR: --solver is required (cg, bpcg, ppcg, dav, dav_subspace)" >&2
    exit 1
fi
if [[ -z "$NP" ]]; then
    echo "ERROR: --np is required" >&2
    exit 1
fi
if [[ -z "$EXAMPLE_DIR" ]]; then
    echo "ERROR: --example is required" >&2
    exit 1
fi
if [[ ! -d "$EXAMPLE_DIR" ]]; then
    echo "ERROR: example directory not found: $EXAMPLE_DIR" >&2
    exit 1
fi
if [[ ! -f "$EXAMPLE_DIR/INPUT" ]]; then
    echo "ERROR: INPUT file not found in: $EXAMPLE_DIR" >&2
    exit 1
fi

# Validate solver name
case "$SOLVER" in
    cg|bpcg|ppcg|dav|dav_subspace) ;;
    *)
        echo "ERROR: unknown solver '$SOLVER'. Valid: cg, bpcg, ppcg, dav, dav_subspace" >&2
        exit 1 ;;
esac

# ── resolve paths ───────────────────────────────────────────────────────────
EXAMPLE_DIR="$(cd "$EXAMPLE_DIR" && pwd)"
EXAMPLE_NAME="$(basename "$EXAMPLE_DIR")"
# Resolve binary to absolute path
_BINARY_DIR="$(cd "$(dirname "$BINARY")" 2>/dev/null && pwd)" || true
if [[ -n "$_BINARY_DIR" ]]; then
    BINARY="$_BINARY_DIR/$(basename "$BINARY")"
fi

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: ABACUS binary not found or not executable: $BINARY" >&2
    echo "  Build it first: cd abacus-develop && cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON && cmake --build build -j\$(nproc)" >&2
    echo "  Then specify with --binary /path/to/abacus" >&2
    exit 1
fi

# Resolve mpirun
if command -v mpirun &>/dev/null; then
    MPIRUN="mpirun"
elif command -v mpiexec &>/dev/null; then
    MPIRUN="mpiexec"
else
    echo "ERROR: mpirun/mpiexec not found in PATH" >&2
    exit 1
fi

# ── setup output directories ────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR/logs"
LOG_FILE="$OUTPUT_DIR/logs/${EXAMPLE_NAME}_${SOLVER}.log"
ERR_FILE="$OUTPUT_DIR/logs/${EXAMPLE_NAME}_${SOLVER}.err"
WORK_DIR="$OUTPUT_DIR/tmp_${EXAMPLE_NAME}_${SOLVER}_$$"

# ── dry run ─────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "=== DRY RUN ==="
    echo "Solver:      $SOLVER"
    echo "MPI procs:   $NP"
    echo "OMP threads: $OMP_NUM_THREADS"
    echo "Example:     $EXAMPLE_DIR"
    echo "Binary:      $BINARY"
    echo "Work dir:    $WORK_DIR"
    echo "Log file:    $LOG_FILE"
    echo "Command:     OMP_NUM_THREADS=$OMP_NUM_THREADS $MPIRUN -np $NP $BINARY"
    exit 0
fi

# ── prepare working directory ────────────────────────────────────────────────
echo "=== Setting up work directory for $EXAMPLE_NAME with solver=$SOLVER ==="
mkdir -p "$WORK_DIR"

# Copy INPUT and modify ks_solver
cp "$EXAMPLE_DIR/INPUT" "$WORK_DIR/INPUT"
# Replace or add ks_solver line
if grep -q '^[[:space:]]*ks_solver' "$WORK_DIR/INPUT"; then
    sed -i "s/^[[:space:]]*ks_solver.*/ks_solver \t\t$SOLVER/" "$WORK_DIR/INPUT"
else
    echo "ks_solver           $SOLVER" >> "$WORK_DIR/INPUT"
fi

# Symlink STRU, KPT
if [[ -f "$EXAMPLE_DIR/STRU" ]]; then
    ln -sf "$EXAMPLE_DIR/STRU" "$WORK_DIR/STRU"
fi
if [[ -f "$EXAMPLE_DIR/KPT" ]]; then
    ln -sf "$EXAMPLE_DIR/KPT" "$WORK_DIR/KPT"
fi

# Symlink pseudopotential files (*.upf, *.UPF)
for f in "$EXAMPLE_DIR"/*.upf "$EXAMPLE_DIR"/*.UPF; do
    [[ -f "$f" ]] || continue
    ln -sf "$f" "$WORK_DIR/$(basename "$f")"
done

# Verify the new INPUT
echo "  Modified ks_solver in INPUT:"
grep 'ks_solver' "$WORK_DIR/INPUT" | head -1

# ── run ABACUS ──────────────────────────────────────────────────────────────
echo ""
echo "=== Running ABACUS: solver=$SOLVER, np=$NP, omp=$OMP_NUM_THREADS ==="
echo "  Work dir: $WORK_DIR"
echo "  Log file: $LOG_FILE"
echo ""

START_TIME=$(date +%s)

# Run ABACUS with timeout
(
    cd "$WORK_DIR"
    export OMP_NUM_THREADS
    if command -v timeout &>/dev/null; then
        timeout "$TIMEOUT_SEC" "$MPIRUN" -np "$NP" "$BINARY"
    else
        "$MPIRUN" -np "$NP" "$BINARY"
    fi
) > "$LOG_FILE" 2> "$ERR_FILE"
EXIT_CODE=$?

END_TIME=$(date +%s)
WALL_TIME=$((END_TIME - START_TIME))

# ── parse results ───────────────────────────────────────────────────────────
echo ""
echo "=== Results: $EXAMPLE_NAME / solver=$SOLVER ==="
echo "Exit code:   $EXIT_CODE"
echo "Wall time:   ${WALL_TIME}s"

# Check for timeout
if [[ $EXIT_CODE -eq 124 ]]; then
    echo "STATUS: TIMEOUT (exceeded ${TIMEOUT_SEC}s)"
fi

# Parse total energy from running_scf.log
SCF_LOG="$WORK_DIR/OUT.autotest/running_scf.log"
if [[ -f "$SCF_LOG" ]]; then
    # Extract the final total energy (last line with "ETOT" or final energy)
    FINAL_ENERGY=$(grep -i 'ETOT' "$SCF_LOG" | tail -1 | awk '{print $NF}' 2>/dev/null || echo "N/A")
    # Also try to parse from the standard ABACUS output format
    if [[ "$FINAL_ENERGY" == "N/A" ]]; then
        FINAL_ENERGY=$(grep -E '^[[:space:]]*[0-9]+[[:space:]]+' "$SCF_LOG" | tail -1 | awk '{print $2}' 2>/dev/null || echo "N/A")
    fi
    # Count SCF iterations
    SCF_STEPS=$(grep -c -i 'ETOT\|^[[:space:]]*CG[0-9]\|^[[:space:]]*[0-9]\+[[:space:]]\+-' "$SCF_LOG" 2>/dev/null || echo "N/A")
    if [[ "$SCF_STEPS" == "0" ]]; then
        # Alternative: count lines with energy values
        SCF_STEPS=$(grep -c -E '^[[:space:]]*[A-Z]+[0-9]+[[:space:]]+' "$SCF_LOG" 2>/dev/null || echo "N/A")
    fi

    echo "Final energy: $FINAL_ENERGY"
    echo "SCF steps:    $SCF_STEPS"
else
    FINAL_ENERGY="N/A"
    SCF_STEPS="N/A"
    echo "WARNING: running_scf.log not found (ABACUS may have crashed before writing output)"
fi

# Parse PPCG-specific diagnostics from stderr
PPCG_ITERS="N/A"
PPCG_LOCKED="N/A"
if [[ "$SOLVER" == "ppcg" ]] && [[ -f "$ERR_FILE" ]]; then
    # Extract PPCG iteration info: "[PPCG] done: niter=42 final_err[0]=..."
    PPCG_ITERS=$(grep -oP '\[PPCG\] done: niter=\K[0-9]+' "$ERR_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "N/A")
    PPCG_LOCKED=$(grep -oP 'locked=\K[0-9/]+' "$ERR_FILE" 2>/dev/null | tail -1 || echo "N/A")
    echo "PPCG iters:   $PPCG_ITERS"
    echo "PPCG locked:  $PPCG_LOCKED"
fi

# ── write result line ───────────────────────────────────────────────────────
RESULT_FILE="$OUTPUT_DIR/results_${EXAMPLE_NAME}.csv"
if [[ ! -f "$RESULT_FILE" ]]; then
    if [[ "$SOLVER" == "ppcg" ]]; then
        echo "solver,np,total_energy,scf_steps,wall_time_s,exit_code,ppcg_iters,ppcg_locked" > "$RESULT_FILE"
    else
        echo "solver,np,total_energy,scf_steps,wall_time_s,exit_code" > "$RESULT_FILE"
    fi
fi

if [[ "$SOLVER" == "ppcg" ]]; then
    echo "$SOLVER,$NP,$FINAL_ENERGY,$SCF_STEPS,$WALL_TIME,$EXIT_CODE,$PPCG_ITERS,$PPCG_LOCKED" >> "$RESULT_FILE"
else
    echo "$SOLVER,$NP,$FINAL_ENERGY,$SCF_STEPS,$WALL_TIME,$EXIT_CODE" >> "$RESULT_FILE"
fi

# ── cleanup temporary working directory ─────────────────────────────────────
# Keep the logs but remove the work directory to save space
echo ""
echo "=== Cleaning up temporary files ==="
rm -rf "$WORK_DIR"
echo "  Removed: $WORK_DIR"
echo "  Logs kept in: $OUTPUT_DIR/logs/"

# ── final status ────────────────────────────────────────────────────────────
if [[ $EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "=== PASS: $EXAMPLE_NAME / $SOLVER (${WALL_TIME}s) ==="
else
    echo ""
    echo "=== FAIL: $EXAMPLE_NAME / $SOLVER (exit=$EXIT_CODE, ${WALL_TIME}s) ===" >&2
    echo "  Check error log: $ERR_FILE" >&2
fi

exit $EXIT_CODE
