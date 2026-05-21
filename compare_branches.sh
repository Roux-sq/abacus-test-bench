#!/bin/bash
# Cross-branch eigenvalue solver benchmark comparison.
# Compares PPCG, BPCG, and Davidson performance between two git branches.
#
# Usage: ./compare_branches.sh [base_branch] [target_branch] [--quick]
#   base_branch   — baseline branch (default: feat/sq_ppcg)
#   target_branch — optimized branch (default: HEAD / current branch)
#   --quick       — use smaller matrix set

set -e

BASE_BRANCH="${1:-feat/sq_ppcg}"
TARGET_BRANCH="${2:-HEAD}"
QUICK=""

for arg in "$@"; do
    [[ "$arg" == "--quick" ]] && QUICK="--quick"
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../abacus-develop" && pwd)"
MPIRUN=/opt/intel/oneapi/mpi/2021.13/bin/mpirun

# Algorithms to benchmark (BPCG and Davidson don't have v1/v2 differences,
# but we compare across branches for consistency)
ALGOS=("ppcg" "bpcg" "david")

echo "=== Eigenvalue Solver Cross-Branch Benchmark ==="
echo "Base:    $BASE_BRANCH"
echo "Target:  $TARGET_BRANCH"
echo "Algos:   ${ALGOS[*]}"
echo ""

ORIG_BRANCH=$(cd "$REPO_DIR" && git branch --show-current)
STASHED=0

cleanup() {
    echo ""
    echo "=== Restoring original state ==="
    cd "$REPO_DIR"
    if [ "$(git branch --show-current 2>/dev/null)" != "$ORIG_BRANCH" ]; then
        git checkout "$ORIG_BRANCH" 2>/dev/null || true
    fi
    if [ $STASHED -eq 1 ]; then
        git stash pop 2>/dev/null || true
    fi
}
trap cleanup EXIT

# revert injected files so git checkout won't fail
uninject_benchmark() {
    local test_dir="$REPO_DIR/source/source_hsolver/test"
    local cmake_file="$test_dir/CMakeLists.txt"

    cd "$REPO_DIR"
    git checkout -- "$cmake_file" 2>/dev/null || true
    rm -f "$test_dir"/diago_*_bench.cpp
}

# inject_benchmark: copy benchmark source and append CMake target.
# Arg: algo name (ppcg, bpcg, david)
inject_benchmark() {
    local algo="$1"
    local test_dir="$REPO_DIR/source/source_hsolver/test"
    local cmake_file="$test_dir/CMakeLists.txt"
    local ppcg_header="$REPO_DIR/source/source_hsolver/diago_ppcg.h"

    # Copy benchmark source
    cp "$SCRIPT_DIR/${algo}_bench.cpp" "$test_dir/diago_${algo}_bench.cpp"

    local target_name="MODULE_HSOLVER_${algo}_bench"

    # Append CMake target if not already present
    if ! grep -q "$target_name" "$cmake_file" 2>/dev/null; then
        case "$algo" in
            ppcg)
                cat >> "$cmake_file" << 'CMAKE_EOF'

  AddTest(
    TARGET MODULE_HSOLVER_ppcg_bench
    LIBS parameter  ${math_libs} base psi device container
    SOURCES diago_ppcg_bench.cpp ../diago_ppcg.cpp ../diago_bpcg.cpp ../para_linear_transform.cpp  ../diago_iter_assist.cpp
            ../../source_basis/module_pw/test/test_tool.cpp
            ../../source_hamilt/operator.cpp
            ../../source_pw/module_pwdft/op_pw.cpp
  )
CMAKE_EOF
                ;;
            bpcg)
                cat >> "$cmake_file" << 'CMAKE_EOF'

  AddTest(
    TARGET MODULE_HSOLVER_bpcg_bench
    LIBS parameter  ${math_libs} base psi device container
    SOURCES diago_bpcg_bench.cpp ../diago_bpcg.cpp ../para_linear_transform.cpp  ../diago_iter_assist.cpp
            ../../source_basis/module_pw/test/test_tool.cpp
            ../../source_hamilt/operator.cpp
            ../../source_pw/module_pwdft/op_pw.cpp
  )
CMAKE_EOF
                ;;
            david)
                cat >> "$cmake_file" << 'CMAKE_EOF'

  AddTest(
    TARGET MODULE_HSOLVER_david_bench
    LIBS parameter  ${math_libs} base psi device
    SOURCES diago_david_bench.cpp ../diago_david.cpp ../diago_iter_assist.cpp ../diag_const_nums.cpp
            ../../source_basis/module_pw/test/test_tool.cpp
            ../../source_hamilt/operator.cpp
            ../../source_pw/module_pwdft/op_pw.cpp
  )
CMAKE_EOF
                ;;
        esac
        echo "  [inject] $target_name added to CMakeLists.txt"
    fi

    # Add PPCG_V2 compile definition for v2-capable branches (PPCG only)
    if [[ "$algo" == "ppcg" ]]; then
        if grep -q "set_block_sizes" "$ppcg_header" 2>/dev/null; then
            if ! grep -q "PPCG_V2" "$cmake_file" 2>/dev/null; then
                echo "  target_compile_definitions(MODULE_HSOLVER_ppcg_bench PRIVATE PPCG_V2)" >> "$cmake_file"
                echo "  [inject] PPCG_V2 compile definition added"
            fi
        fi
    fi
}

# Save any uncommitted changes
cd "$REPO_DIR"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    git stash push -m "bench_compare_autostash" 2>/dev/null || true
    STASHED=1
fi

for algo in "${ALGOS[@]}"; do
    echo ""
    echo "========== Algorithm: $algo =========="

    before_csv="$SCRIPT_DIR/${algo}_before.csv"
    after_csv="$SCRIPT_DIR/${algo}_after.csv"

    # --- Base branch ---
    echo "--- Base branch: $BASE_BRANCH ---"
    git checkout "$BASE_BRANCH" 2>/dev/null
    rm -rf build
    inject_benchmark "$algo"
    CC=/opt/intel/oneapi/mpi/2021.13/bin/mpicc \
    CXX=/opt/intel/oneapi/mpi/2021.13/bin/mpicxx \
    cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DENABLE_LCAO=ON 2>&1 | tail -1
    cmake --build build -j$(nproc) --target "MODULE_HSOLVER_${algo}_bench" 2>&1 | tail -1
    bash "$SCRIPT_DIR/bench_ppcg.sh" --algo "$algo" $QUICK "$before_csv"
    uninject_benchmark

    # --- Target branch ---
    echo "--- Target branch: $TARGET_BRANCH ---"
    git checkout "$TARGET_BRANCH" 2>/dev/null
    rm -rf build
    inject_benchmark "$algo"
    CC=/opt/intel/oneapi/mpi/2021.13/bin/mpicc \
    CXX=/opt/intel/oneapi/mpi/2021.13/bin/mpicxx \
    cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DENABLE_LCAO=ON 2>&1 | tail -1
    cmake --build build -j$(nproc) --target "MODULE_HSOLVER_${algo}_bench" 2>&1 | tail -1
    bash "$SCRIPT_DIR/bench_ppcg.sh" --algo "$algo" $QUICK "$after_csv"
    uninject_benchmark

    # --- Comparison report ---
    echo ""
    echo "=== $algo Comparison ==="
    if [ -f "$before_csv" ] && [ -f "$after_csv" ]; then
        # Determine column layout: BPCG has no iterations
        if [[ "$algo" == "bpcg" ]]; then
            echo "Configuration               Before(ms)  After(ms)  Speedup  MaxErr(before)  MaxErr(after)"
            echo "-------------------------------------------------------------------------------------------"
            tail -n +2 "$before_csv" | while IFS=, read -r npw nband sparsity mpi omp time err; do
                after_line=$(grep "^${npw},${nband},${sparsity},${mpi},${omp}," "$after_csv" 2>/dev/null || echo "")
                if [ -n "$after_line" ]; then
                    after_time=$(echo "$after_line" | cut -d, -f6)
                    after_err=$(echo "$after_line" | cut -d, -f7)
                    if [ -n "$after_time" ] && [ -n "$time" ]; then
                        speedup=$(echo "scale=2; $time / $after_time" | bc 2>/dev/null || echo "N/A")
                        printf "%-28s %10.1f  %9.1f  %7s  %14s  %13s\n" \
                            "${npw}x${npw}/${nband}/s${sparsity}/mpi${mpi}/omp${omp}" \
                            "$time" "$after_time" "${speedup}x" "$err" "$after_err"
                    fi
                fi
            done
        else
            echo "Configuration               Before(ms)  After(ms)  Speedup  Before(iter)  After(iter)"
            echo "---------------------------------------------------------------------------------------"
            tail -n +2 "$before_csv" | while IFS=, read -r npw nband sparsity mpi omp iter time err; do
                after_line=$(grep "^${npw},${nband},${sparsity},${mpi},${omp}," "$after_csv" 2>/dev/null || echo "")
                if [ -n "$after_line" ]; then
                    after_time=$(echo "$after_line" | cut -d, -f7)
                    after_iter=$(echo "$after_line" | cut -d, -f6)
                    if [ -n "$after_time" ] && [ -n "$time" ]; then
                        speedup=$(echo "scale=2; $time / $after_time" | bc 2>/dev/null || echo "N/A")
                        printf "%-28s %10.1f  %9.1f  %7s  %12s  %11s\n" \
                            "${npw}x${npw}/${nband}/s${sparsity}/mpi${mpi}/omp${omp}" \
                            "$time" "$after_time" "${speedup}x" "$iter" "$after_iter"
                    fi
                fi
            done
        fi
        echo ""
        echo "Before: $before_csv"
        echo "After:  $after_csv"
    else
        echo "Missing result files — benchmark may have failed."
    fi
done

echo ""
echo "=== All comparisons complete ==="
