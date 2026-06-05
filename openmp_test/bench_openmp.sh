#!/bin/bash
# ==============================================================================
# ABACUS Eigenvalue Solver OpenMP Benchmark
# Compatible with both feat/openmp_opt and feat/openmp_v2 branches.
#
# Usage:
#   ./bench_openmp.sh [OPTIONS]
#
# Options:
#   --algo ppcg|bpcg|david    Solver to benchmark (default: all three)
#   --quick                    Use small test matrix for fast validation
#   --medium                   Use medium test matrices (default)
#   --full                     Use large test matrices for scaling analysis
#   --threads "1 2 4 8"        OMP_NUM_THREADS values (default: "1 2 4")
#   --build-dir PATH           Build directory (default: ../abacus-develop/build)
#   --output-dir PATH          Output directory (default: ./results)
#   --timeout SEC              Per-run timeout in seconds (default: 300)
#   --no-build                 Skip build step (assumes already built)
#   --mpi-procs N              MPI process count (default: 1)
#
# Examples:
#   ./bench_openmp.sh --quick                                    # Fast check of all solvers
#   ./bench_openmp.sh --algo bpcg --threads "1 2 4 8 16"        # BPCG scaling
#   ./bench_openmp.sh --full --algo ppcg --output-dir ppcg_full  # PPCG large-scale
# ==============================================================================

set -uo pipefail

# ---- defaults ----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(cd "$SCRIPT_DIR/../../abacus-develop/build" 2>/dev/null && pwd || echo '')"
OUTPUT_DIR="$SCRIPT_DIR/results"
ALGO="all"
MODE="medium"
OMP_THREADS="1 2 4"
TIMEOUT=300
SKIP_BUILD=0
MPI_PROCS=1

# ---- helpers ----
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ---- find mpirun ----
find_mpirun() {
    for candidate in mpirun /usr/bin/mpirun /usr/lib64/openmpi/bin/mpirun; do
        if command -v "$candidate" &>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

# ---- argument parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --algo)       ALGO="$2"; shift 2 ;;
        --algo=*)     ALGO="${1#*=}"; shift ;;
        --quick)      MODE="quick"; shift ;;
        --medium)     MODE="medium"; shift ;;
        --full)       MODE="full"; shift ;;
        --threads)    OMP_THREADS="$2"; shift 2 ;;
        --threads=*)  OMP_THREADS="${1#*=}"; shift ;;
        --build-dir)  BUILD_DIR="$2"; shift 2 ;;
        --build-dir=*) BUILD_DIR="${1#*=}"; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}"; shift ;;
        --timeout)    TIMEOUT="$2"; shift 2 ;;
        --timeout=*)  TIMEOUT="${1#*=}"; shift ;;
        --no-build)   SKIP_BUILD=1; shift ;;
        --mpi-procs)  MPI_PROCS="$2"; shift 2 ;;
        --mpi-procs=*) MPI_PROCS="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---- validate ----
[[ -z "$BUILD_DIR" ]] && die "Cannot find build directory. Use --build-dir PATH."
[[ -d "$BUILD_DIR" ]] || die "Build directory does not exist: $BUILD_DIR"

MPIRUN=$(find_mpirun)
[[ -z "$MPIRUN" ]] && log "WARNING: mpirun not found; running without MPI wrapper."
MPIRUN="${MPIRUN:-}"

TEST_DIR="$BUILD_DIR/source/source_hsolver/test"
BIN_DIR="$TEST_DIR"

# ---- test configs ----
declare -A CONFIGS
case "$MODE" in
    quick)
        CONFIGS=(
            ["200x10x0"]="--npw 200 --nband 10 --sparsity 0 --ethr 1e-2"
            ["400x20x5"]="--npw 400 --nband 20 --sparsity 5 --ethr 1e-2"
        )
        OMP_THREADS="1 2"
        ;;
    medium)
        CONFIGS=(
            ["200x10x0"]="--npw 200 --nband 10 --sparsity 0 --ethr 1e-4"
            ["500x30x6"]="--npw 500 --nband 30 --sparsity 6 --ethr 1e-4"
            ["1000x50x8"]="--npw 1000 --nband 50 --sparsity 8 --ethr 1e-4"
            ["2000x100x8"]="--npw 2000 --nband 100 --sparsity 8 --ethr 1e-4"
        )
        ;;
    full)
        CONFIGS=(
            ["500x20x4"]="--npw 500 --nband 20 --sparsity 4 --ethr 1e-5"
            ["1000x50x8"]="--npw 1000 --nband 50 --sparsity 8 --ethr 1e-5"
            ["2000x100x8"]="--npw 2000 --nband 100 --sparsity 8 --ethr 1e-5"
            ["5000x200x10"]="--npw 5000 --nband 200 --sparsity 10 --ethr 1e-5"
            ["10000x300x12"]="--npw 10000 --nband 300 --sparsity 12 --ethr 1e-5"
        )
        OMP_THREADS="1 2 4 8 16"
        ;;
esac

# ---- which algorithms ----
case "$ALGO" in
    all)   ALGOS=("ppcg" "bpcg" "david") ;;
    ppcg)  ALGOS=("ppcg") ;;
    bpcg)  ALGOS=("bpcg") ;;
    david) ALGOS=("david") ;;
    *)     die "Unknown algorithm: $ALGO (expected: ppcg, bpcg, david, all)" ;;
esac

# ---- build ----
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    log "Building benchmark targets..."
    TARGETS=""
    for algo in "${ALGOS[@]}"; do
        TARGETS="$TARGETS MODULE_HSOLVER_${algo}_bench"
    done
    cmake --build "$BUILD_DIR" -j"$(nproc)" --target $TARGETS 2>&1 | tail -3 \
        || die "Build failed. Check CMake configuration in $BUILD_DIR"
    log "Build complete."
else
    log "Skipping build (--no-build)."
fi

# ---- verify binaries exist ----
for algo in "${ALGOS[@]}"; do
    bin="$BIN_DIR/MODULE_HSOLVER_${algo}_bench"
    [[ -x "$bin" ]] || die "Binary not found: $bin"
done

# ---- run benchmarks ----
mkdir -p "$OUTPUT_DIR"

run_benchmark() {
    local algo="$1" bin="$2" label="$3" npw="$4" nband="$5" sparsity="$6" ethr="$7"

    for omp in $OMP_THREADS; do
        log "  $algo / $label / OMP=$omp"

        local extra_args=""
        [[ "$algo" == "ppcg" ]] && extra_args="0 0"

        local cmd="OMP_NUM_THREADS=$omp"
        if [[ -n "$MPIRUN" ]]; then
            cmd="$cmd $MPIRUN -np $MPI_PROCS"
        fi
        cmd="$cmd $bin $npw $nband $sparsity $ethr $extra_args"

        local output
        output=$(timeout "$TIMEOUT" bash -c "$cmd" 2>/dev/null) || {
            # Build failure line dynamically from CSV header
            echo "FAIL,$npw,$nband,$sparsity,$MPI_PROCS,$omp,FAILED"
            continue
        }

        # Extract the CSV data line (skip noise like "hwlocs" etc.)
        echo "$output" | grep -E '^[0-9]+,[0-9]+,[0-9]+,[0-9]+,' | head -1
    done
}

# ---- generate results ----
for algo in "${ALGOS[@]}"; do
    bin="$BIN_DIR/MODULE_HSOLVER_${algo}_bench"
    output_csv="$OUTPUT_DIR/${algo}_bench_${MODE}.csv"

    log "Benchmarking: $algo ($MODE)"

    # Build CSV header dynamically based on algo
    case "$algo" in
        bpcg)  HEADER="npw,nband,sparsity,mpi_procs,omp_threads,time_ms,max_error" ;;
        ppcg)  HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error" ;;
        david) HEADER="npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error" ;;
    esac

    {
        echo "$HEADER"
        for label in "${!CONFIGS[@]}"; do
            read -r _ npw_val _ nband_val _ sparsity_val _ ethr_val <<< \
                "$(echo "${CONFIGS[$label]}" | sed 's/--//g; s/=/ /g')"
            run_benchmark "$algo" "$bin" "$label" \
                "$npw_val" "$nband_val" "$sparsity_val" "$ethr_val"
        done
    } > "$output_csv"

    log "Results: $output_csv ($(($(wc -l < "$output_csv") - 1)) data rows)"
done

# ---- summary ----
log "All benchmarks complete."
log "Results directory: $OUTPUT_DIR"
echo ""
echo "=== Quick Summary ==="
for algo in "${ALGOS[@]}"; do
    csv="$OUTPUT_DIR/${algo}_bench_${MODE}.csv"
    echo "--- $algo ---"
    if [[ -f "$csv" ]]; then
        column -t -s, "$csv" 2>/dev/null | head -20 || cat "$csv"
    fi
done
