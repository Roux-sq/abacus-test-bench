#!/bin/bash
# Cross-branch eigenvalue solver benchmark comparison.
# Only PPCG is compared across branches (BPCG / David are identical in feat/sq_*).
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

echo "=== Eigenvalue Solver Cross-Branch Benchmark ==="
echo "Base:    $BASE_BRANCH"
echo "Target:  $TARGET_BRANCH"
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

# Revert injected CMake targets (but keep benchmark .cpp files so
# other compilation workflows stay functional after this script ends).
uninject_benchmark() {
    local cmake_file="$REPO_DIR/source/source_hsolver/test/CMakeLists.txt"
    cd "$REPO_DIR"
    git checkout -- "$cmake_file" 2>/dev/null || true
}

# inject_benchmark: copy benchmark source and append CMake target.
# Uses add_executable (not AddTest) so the benchmark's own main()
# won't conflict with gtest_main.
inject_benchmark() {
    local algo="$1"
    local test_dir="$REPO_DIR/source/source_hsolver/test"
    local cmake_file="$test_dir/CMakeLists.txt"

    # Copy benchmark source
    cp "$SCRIPT_DIR/${algo}_bench.cpp" "$test_dir/diago_${algo}_bench.cpp"

    local target_name="MODULE_HSOLVER_${algo}_bench"

    if ! grep -q "$target_name" "$cmake_file" 2>/dev/null; then
        case "$algo" in
            ppcg)
                cat >> "$cmake_file" << 'CMAKE_EOF'

add_executable(MODULE_HSOLVER_ppcg_bench
  diago_ppcg_bench.cpp ../diago_ppcg.cpp ../diago_bpcg.cpp ../para_linear_transform.cpp ../diago_iter_assist.cpp
  ../../source_basis/module_pw/test/test_tool.cpp
  ../../source_hamilt/operator.cpp
  ../../source_pw/module_pwdft/op_pw.cpp
)
target_link_libraries(MODULE_HSOLVER_ppcg_bench PRIVATE parameter ${math_libs} base psi device container Threads::Threads)
if(USE_OPENMP)
  target_link_libraries(MODULE_HSOLVER_ppcg_bench PRIVATE OpenMP::OpenMP_CXX)
endif()
CMAKE_EOF
                ;;
            bpcg)
                cat >> "$cmake_file" << 'CMAKE_EOF'

add_executable(MODULE_HSOLVER_bpcg_bench
  diago_bpcg_bench.cpp ../diago_bpcg.cpp ../para_linear_transform.cpp ../diago_iter_assist.cpp
  ../../source_basis/module_pw/test/test_tool.cpp
  ../../source_hamilt/operator.cpp
  ../../source_pw/module_pwdft/op_pw.cpp
)
target_link_libraries(MODULE_HSOLVER_bpcg_bench PRIVATE parameter ${math_libs} base psi device container Threads::Threads)
if(USE_OPENMP)
  target_link_libraries(MODULE_HSOLVER_bpcg_bench PRIVATE OpenMP::OpenMP_CXX)
endif()
CMAKE_EOF
                ;;
            david)
                cat >> "$cmake_file" << 'CMAKE_EOF'

add_executable(MODULE_HSOLVER_david_bench
  diago_david_bench.cpp ../diago_david.cpp ../diago_iter_assist.cpp ../diag_const_nums.cpp
  ../../source_basis/module_pw/test/test_tool.cpp
  ../../source_hamilt/operator.cpp
  ../../source_pw/module_pwdft/op_pw.cpp
)
target_link_libraries(MODULE_HSOLVER_david_bench PRIVATE parameter ${math_libs} base psi device Threads::Threads)
if(USE_OPENMP)
  target_link_libraries(MODULE_HSOLVER_david_bench PRIVATE OpenMP::OpenMP_CXX)
endif()
CMAKE_EOF
                ;;
        esac
        echo "  [inject] $target_name added to CMakeLists.txt"
    fi
}

# --- Save any uncommitted changes ---
cd "$REPO_DIR"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    git stash push -m "bench_compare_autostash" 2>/dev/null || true
    STASHED=1
fi

# ============================================================
# BPCG / David — identical on both branches, test once only
# ============================================================
for algo in bpcg david; do
    echo ""
    echo "========== Algorithm: $algo (once, same on both branches) =========="

    out_csv="$SCRIPT_DIR/${algo}_bench.csv"

    git checkout "$BASE_BRANCH" 2>/dev/null
    rm -rf build
    inject_benchmark "$algo"
    CC=/opt/intel/oneapi/mpi/2021.13/bin/mpicc \
    CXX=/opt/intel/oneapi/mpi/2021.13/bin/mpicxx \
    cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DENABLE_LCAO=ON 2>&1 | tail -1
    cmake --build build -j$(nproc) --target "MODULE_HSOLVER_${algo}_bench" 2>&1 | tail -1
    bash "$SCRIPT_DIR/bench_ppcg.sh" --algo "$algo" $QUICK "$out_csv"
    uninject_benchmark

    echo "  Results: $out_csv"
done

# ============================================================
# PPCG — cross-branch comparison (only solver with v1 / v2 diff)
# ============================================================
echo ""
echo "========== Algorithm: ppcg (cross-branch) =========="

before_csv="$SCRIPT_DIR/ppcg_before.csv"
after_csv="$SCRIPT_DIR/ppcg_after.csv"

# --- Base branch (v1, per-band mode) ---
echo "--- Base branch: $BASE_BRANCH (per-band) ---"
git checkout "$BASE_BRANCH" 2>/dev/null
rm -rf build
inject_benchmark "ppcg"
CC=/opt/intel/oneapi/mpi/2021.13/bin/mpicc \
CXX=/opt/intel/oneapi/mpi/2021.13/bin/mpicxx \
cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DENABLE_LCAO=ON 2>&1 | tail -1
cmake --build build -j$(nproc) --target MODULE_HSOLVER_ppcg_bench 2>&1 | tail -1
bash "$SCRIPT_DIR/bench_ppcg.sh" --algo ppcg $QUICK "$before_csv"
uninject_benchmark

# --- Target branch (v2, blocked variant with block_size=4, no extra bands) ---
echo "--- Target branch: $TARGET_BRANCH (block_size=4) ---"
git checkout "$TARGET_BRANCH" 2>/dev/null
rm -rf build
inject_benchmark "ppcg"
CC=/opt/intel/oneapi/mpi/2021.13/bin/mpicc \
CXX=/opt/intel/oneapi/mpi/2021.13/bin/mpicxx \
cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DENABLE_LCAO=ON 2>&1 | tail -1
cmake --build build -j$(nproc) --target MODULE_HSOLVER_ppcg_bench 2>&1 | tail -1
bash "$SCRIPT_DIR/bench_ppcg.sh" --algo ppcg --block 4 $QUICK "$after_csv"
uninject_benchmark

# --- PPCG comparison report ---
echo ""
echo "=== ppcg Comparison ==="
if [ -f "$before_csv" ] && [ -f "$after_csv" ]; then
    echo "Configuration               Before(ms)  After(ms)  Speedup  Before(iter)  After(iter)"
    echo "---------------------------------------------------------------------------------------"
    tail -n +2 "$before_csv" | while IFS=, read -r npw nband sparsity mpi omp iter time err rest; do
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
    echo ""
    echo "Before (per-band): $before_csv"
    echo "After  (block=4):  $after_csv"
else
    echo "Missing result files — benchmark may have failed."
fi

echo ""
echo "=== All comparisons complete ==="
