#!/bin/bash
# MPI consistency check for eigenvalue solvers.
# Verifies that BPCG and Davidson produce identical results
# across different MPI process counts.

set +e

MPIRUN=/usr/bin/mpirun
BUILD_DIR=$(cd "$(dirname "$0")/../abacus-develop/build" && pwd)

BPCG_BIN="$BUILD_DIR/source/source_hsolver/test/MODULE_HSOLVER_bpcg_bench"
DAVID_BIN="$BUILD_DIR/source/source_hsolver/test/MODULE_HSOLVER_david_bench"

export OMP_NUM_THREADS=1

# Test configurations: npw nband sparsity ethr
CONFIGS=(
    "100 10 0 1e-7"
    "200 20 5 1e-7"
)

PASS=0
FAIL=0

echo "=== MPI Consistency Check ==="
echo ""

for cfg in "${CONFIGS[@]}"; do
    read -r npw nband sparsity ethr <<< "$cfg"
    
    echo "--- Config: ${npw}x${npw}/${nband}/s${sparsity} ---"
    
    # BPCG
    if [ -x "$BPCG_BIN" ]; then
        ref=$($MPIRUN -np 1 $BPCG_BIN $npw $nband $sparsity $ethr 2>/dev/null | grep -v "hwloc\|Pass --enable")
        ref_err=$(echo "$ref" | awk -F, '{print $7}')
        
        for np in 2 4; do
            test=$($MPIRUN -np $np $BPCG_BIN $npw $nband $sparsity $ethr 2>/dev/null | grep -v "hwloc\|Pass --enable" | tail -n 1)
            test_err=$(echo "$test" | awk -F, '{print $7}')
            
            if [ "$ref_err" = "$test_err" ]; then
                echo "  BPCG np=$np: PASS (err=$test_err)"
                ((PASS++))
            else
                echo "  BPCG np=$np: FAIL (ref_err=$ref_err, test_err=$test_err)"
                ((FAIL++))
            fi
        done
    fi
    
    # Davidson
    if [ -x "$DAVID_BIN" ]; then
        ref=$($MPIRUN -np 1 $DAVID_BIN $npw $nband $sparsity $ethr 2>/dev/null | grep -v "hwloc\|Pass --enable")
        ref_err=$(echo "$ref" | awk -F, '{print $8}')
        
        for np in 2 4; do
            test=$($MPIRUN -np $np $DAVID_BIN $npw $nband $sparsity $ethr 2>/dev/null | grep -v "hwloc\|Pass --enable" | tail -n 1)
            test_err=$(echo "$test" | awk -F, '{print $8}')
            
            if [ "$ref_err" = "$test_err" ]; then
                echo "  Davidson np=$np: PASS (err=$test_err)"
                ((PASS++))
            else
                echo "  Davidson np=$np: FAIL (ref_err=$ref_err, test_err=$test_err)"
                ((FAIL++))
            fi
        done
    fi
    echo ""
done

echo "=== Summary: $PASS passed, $FAIL failed ==="
exit $FAIL
