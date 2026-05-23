#!/bin/bash
# Eigenvalue solver benchmark — measures runtime and iterations across matrix sizes and thread counts.
#
# Usage: ./bench_ppcg.sh [--quick] [--algo ppcg|bpcg|david] [--extra N] [--block N] [output.csv]
#   --quick     : smaller matrix set for fast validation
#   --algo NAME : solver to benchmark (default: ppcg)
#   --extra N   : n_extra parameter (PPCG only, default 0)
#   --block N   : block_size parameter (PPCG only, default 0)
#   output.csv  : result file path

set -e

MPIRUN=/opt/intel/oneapi/mpi/2021.13/bin/mpirun
BUILD_DIR=$(cd "$(dirname "$0")/../abacus-develop/build" && pwd)

ALGO="ppcg"
QUICK=0
EXTRA=0
BLOCK=0
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK=1; shift ;;
        --algo)
            ALGO="$2"; shift 2 ;;
        --algo=*)
            ALGO="${1#--algo=}"; shift ;;
        --extra)
            EXTRA="$2"; shift 2 ;;
        --extra=*)
            EXTRA="${1#--extra=}"; shift ;;
        --block)
            BLOCK="$2"; shift 2 ;;
        --block=*)
            BLOCK="${1#--block=}"; shift ;;
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
        "100  10  0  1e-2"
        "200  20  6  1e-2"
    )
else
    CONFIGS=(
        "100  10  0  1e-2"
        "500  50  6  1e-2"
        "1000 100 8  1e-2"
        "200  20  5  1e-2"
    )
fi

OMP_THREADS=(1 2 4)

# Build header and fail line. PPCG may have extra columns for n_extra / block_size.
if [[ "$ALGO" == "bpcg" ]]; then
    HEADER="npw,nband,sparsity,mpi_procs,omp_threads,time_ms,max_error"
    FAIL_LINE='${npw},${nband},${sparsity},1,${omp},FAIL,FAIL'
elif [[ "$ALGO" == "ppcg" ]]; then
    HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error"
    FAIL_LINE='${npw},${nband},${sparsity},1,${omp},FAIL,FAIL,FAIL'
    if [[ "$EXTRA" -gt 0 || "$BLOCK" -gt 0 ]]; then
        HEADER="${HEADER},n_extra,block_size"
        FAIL_LINE="${FAIL_LINE},FAIL,FAIL"
    fi
else
    HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error"
    FAIL_LINE='${npw},${nband},${sparsity},1,${omp},FAIL,FAIL,FAIL'
fi

BIN_ARGS="$EXTRA $BLOCK"

{
    echo "$HEADER"

    for cfg in "${CONFIGS[@]}"; do
        read -r npw nband sparsity ethr <<< "$cfg"
        for omp in "${OMP_THREADS[@]}"; do
            export OMP_NUM_THREADS=$omp
            timeout 120 $MPIRUN -np 1 $BENCH_BIN $npw $nband $sparsity $ethr $BIN_ARGS 2>/dev/null || eval echo $FAIL_LINE
        done
    done
} > "$OUTPUT"

echo "Results written to $OUTPUT" >&2
