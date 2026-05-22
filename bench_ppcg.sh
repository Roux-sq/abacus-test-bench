#!/bin/bash
# Eigenvalue solver benchmark — measures runtime and iterations across matrix sizes and thread counts.
#
# Usage: ./bench_ppcg.sh [--quick] [--algo ppcg|bpcg|david] [output.csv]
#   --quick     : smaller matrix set for fast validation
#   --algo NAME : solver to benchmark (default: ppcg)
#   output.csv  : result file path

set -e

MPIRUN=/opt/intel/oneapi/mpi/2021.13/bin/mpirun
BUILD_DIR=$(cd "$(dirname "$0")/../abacus-develop/build" && pwd)

ALGO="ppcg"
QUICK=0
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK=1; shift ;;
        --algo)
            ALGO="$2"; shift 2 ;;
        --algo=*)
            ALGO="${1#--algo=}"; shift ;;
        *)
            OUTPUT="$1"; shift ;;
    esac
done

case "$ALGO" in
    ppcg)  BIN_NAME="MODULE_HSOLVER_ppcg_bench" ;;
    bpcg)  BIN_NAME="MODULE_HSOLVER_bpcg_bench" ;;
    david) BIN_NAME="MODULE_HSOLVER_david_bench" ;;
    *)
        echo "Unknown algorithm: $ALGO (expected: ppcg, bpcg, david)" >&2
        exit 1 ;;
esac

BENCH_BIN="$BUILD_DIR/source/source_hsolver/test/$BIN_NAME"
OUTPUT="${OUTPUT:-${ALGO}_bench_results.csv}"

if [[ "$QUICK" -eq 1 ]]; then
    CONFIGS=(
        "100  10  0  1e-7"
        "200  20  6  1e-7"
    )
else
    CONFIGS=(
        "100  10  0  1e-7"
        "500  50  6  1e-7"
        "1000 100 8  1e-7"
        "200  20  5  1e-7"
    )
fi

OMP_THREADS=(1 2 4)

# BPCG diag() returns void — no iteration count in output
if [[ "$ALGO" == "bpcg" ]]; then
    HEADER="npw,nband,sparsity,mpi_procs,omp_threads,time_ms,max_error"
    FAIL_LINE='${npw},${nband},${sparsity},1,${omp},FAIL,FAIL'
else
    HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error"
    FAIL_LINE='${npw},${nband},${sparsity},1,${omp},FAIL,FAIL,FAIL'
fi

{
    echo "$HEADER"

    for cfg in "${CONFIGS[@]}"; do
        read -r npw nband sparsity ethr <<< "$cfg"
        for omp in "${OMP_THREADS[@]}"; do
            export OMP_NUM_THREADS=$omp
            timeout 120 $MPIRUN -np 1 $BENCH_BIN $npw $nband $sparsity $ethr 2>/dev/null || echo $FAIL_LINE
        done
    done
} > "$OUTPUT"

echo "Results written to $OUTPUT" >&2
