#!/bin/bash
# ==============================================================================
# ABACUS OpenMP Branch Comparison Tool
# Compares eigenvalue solver performance between two branches.
# Designed for feat/openmp_opt vs feat/openmp_v2 comparison.
#
# Usage:
#   ./compare_branches.sh [--base BRANCH] [--target BRANCH] [OPTIONS]
#
# Options:
#   --base BRANCH       Baseline branch (default: feat/openmp_opt)
#   --target BRANCH     Comparison branch (default: feat/openmp_v2)
#   --quick             Use small matrices for fast comparison
#   --medium            Use medium matrices (default)
#   --algo A            Solver(s): ppcg|bpcg|david|all (default: all)
#   --threads "1 2 4"   OMP_NUM_THREADS (default: "1 2 4")
#   --repo PATH         Path to abacus-develop repo (default: ../abacus-develop)
#
# Examples:
#   ./compare_branches.sh --quick                           # Fast comparison
#   ./compare_branches.sh --algo bpcg --threads "1 2 4 8"   # BPCG scaling
#   ./compare_branches.sh --base develop --target feat/openmp_v2
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_SCRIPT="$SCRIPT_DIR/bench_openmp.sh"

BASE_BRANCH="feat/openmp_opt"
TARGET_BRANCH="feat/openmp_v2"
REPO_DIR=""
MODE="medium"
ALGO="all"
OMP_THREADS="1 2 4"

# ---- helpers ----
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# ---- parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)       BASE_BRANCH="$2"; shift 2 ;;
        --base=*)     BASE_BRANCH="${1#*=}"; shift ;;
        --target)     TARGET_BRANCH="$2"; shift 2 ;;
        --target=*)   TARGET_BRANCH="${1#*=}"; shift ;;
        --quick)      MODE="quick"; shift ;;
        --medium)     MODE="medium"; shift ;;
        --algo)       ALGO="$2"; shift 2 ;;
        --algo=*)     ALGO="${1#*=}"; shift ;;
        --threads)    OMP_THREADS="$2"; shift 2 ;;
        --threads=*)  OMP_THREADS="${1#*=}"; shift ;;
        --repo)       REPO_DIR="$2"; shift 2 ;;
        --repo=*)     REPO_DIR="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,26p' "$0"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---- find repo ----
if [[ -z "$REPO_DIR" ]]; then
    REPO_DIR="$(cd "$SCRIPT_DIR/../../abacus-develop" 2>/dev/null && pwd)" || \
        die "Cannot find abacus-develop. Use --repo PATH."
fi
[[ -d "$REPO_DIR/.git" ]] || die "Not a git repository: $REPO_DIR"

# ---- verify branches exist ----
cd "$REPO_DIR"
git fetch --all --prune 2>/dev/null || true

for branch in "$BASE_BRANCH" "$TARGET_BRANCH"; do
    if ! git rev-parse --verify "$branch" &>/dev/null; then
        die "Branch not found: $branch"
    fi
done

# ---- save current state ----
ORIG_BRANCH=$(git branch --show-current)
ORIG_DIRTY=0
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    ORIG_DIRTY=1
    log "Stashing uncommitted changes on $ORIG_BRANCH..."
    git stash push -m "bench_compare_autostash" 2>/dev/null || true
fi

cleanup() {
    log "Restoring original state..."
    cd "$REPO_DIR"
    if [[ "$(git branch --show-current 2>/dev/null)" != "$ORIG_BRANCH" ]]; then
        git checkout "$ORIG_BRANCH" 2>/dev/null || true
    fi
    if [[ $ORIG_DIRTY -eq 1 ]]; then
        git stash pop 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---- run benchmarks on a branch ----
run_on_branch() {
    local branch="$1" label="$2"
    local branch_build="$REPO_DIR/build_${label}"
    local out_dir="$SCRIPT_DIR/results_${label}"

    log "Switching to $branch..."
    cd "$REPO_DIR"
    git checkout "$branch" 2>/dev/null || die "Cannot checkout $branch"
    local commit=$(git rev-parse --short HEAD)

    log "Configuring build ($commit)..."
    cmake -B "$branch_build" -DBUILD_TESTING=ON -DENABLE_MPI=ON -DUSE_OPENMP=ON \
        2>&1 | tail -1 || die "CMake configure failed on $branch"

    log "Running benchmarks..."
    bash "$BENCH_SCRIPT" \
        --build-dir "$branch_build" \
        --output-dir "$out_dir" \
        --algo "$ALGO" \
        --"$MODE" \
        --threads "$OMP_THREADS" \
        --no-build

    log "Done on $branch ($commit)."
    echo "$commit" > "$out_dir/.commit"
}

# ---- main ----
log "=== OpenMP Branch Comparison ==="
log "Base:   $BASE_BRANCH"
log "Target: $TARGET_BRANCH"
log "Mode:   $MODE | Algo: $ALGO | Threads: $OMP_THREADS"
echo ""

# Build and run on BASE branch
run_on_branch "$BASE_BRANCH" "base"

# Build and run on TARGET branch
run_on_branch "$TARGET_BRANCH" "target"

# ---- generate comparison report ----
log "Generating comparison report..."
REPORT="$SCRIPT_DIR/comparison_report.txt"

{
    echo "=== ABACUS OpenMP Branch Comparison ==="
    echo "Base branch:   $BASE_BRANCH ($(cat "$SCRIPT_DIR/results_base/.commit" 2>/dev/null || echo unknown))"
    echo "Target branch: $TARGET_BRANCH ($(cat "$SCRIPT_DIR/results_target/.commit" 2>/dev/null || echo unknown))"
    echo "Mode: $MODE | Algo: $ALGO | Threads: $OMP_THREADS"
    echo "Date: $(date)"
    echo ""

    for algo in ${ALGO//all/ppcg bpcg david}; do
        base_csv="$SCRIPT_DIR/results_base/${algo}_bench_${MODE}.csv"
        target_csv="$SCRIPT_DIR/results_target/${algo}_bench_${MODE}.csv"

        echo "============================================================"
        echo "Algorithm: $algo"
        echo "============================================================"

        if [[ ! -f "$base_csv" || ! -f "$target_csv" ]]; then
            echo "  (missing data -- benchmark may have failed)"
            echo ""
            continue
        fi

        printf "%-30s %8s %8s %8s %12s %12s %10s\n" \
            "Config" "OMP" "Base(ms)" "Target(ms)" "Base(iter)" "Target(iter)" "Speedup"
        echo "--------------------------------------------------------------------------------"

        # Skip header
        tail -n +2 "$base_csv" | while IFS=',' read -r npw nband sparsity mpi omp rest; do
            # Find matching row in target CSV
            target_line=$(grep "^${npw},${nband},${sparsity},${mpi},${omp}," "$target_csv" 2>/dev/null | head -1)
            if [[ -z "$target_line" ]]; then
                continue
            fi

            # Extract time columns: bpcg=col6 ppcg/david=col7
            if [[ "$algo" == "bpcg" ]]; then
                base_time=$(echo "$rest" | cut -d, -f1)
                target_time=$(echo "$target_line" | cut -d, -f6)
                base_iter="N/A"
                target_iter="N/A"
                base_err=$(echo "$rest" | cut -d, -f2)
                target_err=$(echo "$target_line" | cut -d, -f7)
            else
                base_iter=$(echo "$rest" | cut -d, -f1)
                base_time=$(echo "$rest" | cut -d, -f2)
                target_iter=$(echo "$target_line" | cut -d, -f6)
                target_time=$(echo "$target_line" | cut -d, -f7)
            fi

            # Compute speedup
            speedup="N/A"
            if [[ -n "$base_time" && -n "$target_time" && "$target_time" != "0" ]]; then
                speedup=$(awk "BEGIN { printf \"%.2fx\", $base_time / $target_time }" 2>/dev/null || echo "N/A")
            fi

            label="${npw}/${nband}/s${sparsity}"
            printf "%-30s %8s %8.1f %8.1f %12s %12s %10s\n" \
                "$label" "$omp" "${base_time:-N/A}" "${target_time:-N/A}" \
                "${base_iter:-N/A}" "${target_iter:-N/A}" "${speedup:-N/A}"
        done
        echo ""
    done

    echo "=== End of Report ==="

} > "$REPORT"

cat "$REPORT"
log "Report saved to: $REPORT"
log "Raw data: $SCRIPT_DIR/results_base/  and  $SCRIPT_DIR/results_target/"
log "=== All done ==="
