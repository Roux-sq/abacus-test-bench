#!/bin/bash
# PPCG CUDA benchmark — measures runtime and iterations on GPU.
#
# Usage: ./bench_ppcg_cuda.sh [--quick] [output.csv]
#   --quick     : smaller matrix set for fast validation
#   output.csv  : result file path (default: ppcg_cuda_bench_results.csv)
#
# Prerequisites:
#   - ABACUS built with USE_CUDA=ON
#   - CUDA-capable GPU available

set -e

BUILD_DIR=$(cd "$(dirname "$0")/../abacus-develop/build" && pwd)
QUICK=0
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK=1; shift ;;
        *)
            OUTPUT="$1"; shift ;;
    esac
done

BIN_NAME="MODULE_HSOLVER_ppcg_bench_cuda"
BENCH_BIN="$BUILD_DIR/source/source_hsolver/test/$BIN_NAME"
OUTPUT="${OUTPUT:-ppcg_cuda_bench_results.csv}"

if [[ ! -x "$BENCH_BIN" ]]; then
    echo "ERROR: $BENCH_BIN not found or not executable." >&2
    echo "Please build ABACUS with USE_CUDA=ON (e.g. cmake -DUSE_CUDA=ON ...)." >&2
    exit 1
fi

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

HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error"
FAIL_LINE='${npw},${nband},${sparsity},1,1,FAIL,FAIL,FAIL'

{
    echo "$HEADER"

    for cfg in "${CONFIGS[@]}"; do
        read -r npw nband sparsity ethr <<< "$cfg"
        # GPU runs typically use a single host thread
        export OMP_NUM_THREADS=1
        timeout 300 $BENCH_BIN $npw $nband $sparsity $ethr 2>/dev/null || echo $FAIL_LINE
    done
} > "$OUTPUT"

echo "Results written to $OUTPUT" >&2
