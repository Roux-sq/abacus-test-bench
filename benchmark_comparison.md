# ABACUS Solver Benchmark 完整对比报告

## 1. 测试环境

| 项目 | 配置 |
|:---|:---|
| CPU | x86_64 (多核) |
| GPU | NVIDIA GeForce RTX 4080 Laptop |
| CUDA Driver | 580.159.03 |
| CUDA Toolkit | 13.3 (conda 环境 `abacus`) |
| ABACUS | `abacus-develop` (commit 66f4f8536) |
| C++ 编译器 | `/usr/bin/g++` 11.4 |
| CUDA 编译器 | conda `nvcc` 13.3，host compiler = `/usr/bin/g++` |
| BLAS | OpenBLAS (系统) |
| MPI | OpenMPI (系统) |
| 运行设置 | `OMP_NUM_THREADS=1`（统一单线程对比） |

> **关于 PPCG CPU 速度差异的说明**：前一轮对话中未设置 `OMP_NUM_THREADS`，系统默认多线程导致 PPCG 因 OpenMP 同步开销而降速。本报告所有数据均在 `OMP_NUM_THREADS=1` 下测得，与历史 CSV（`ppcg_before.csv` 等）一致。

---

## 2. 核心修复：PPCG GPU 数值 Bug

**根因**：`diago_ppcg.cpp` 的 `update_vectors_from_ppcg_subspace()` 中，`gemv` 接收的 `A` 矩阵指针 `bv[0]` 仅指向**单个列向量**，但代码意图传入由 `[xi, wi, pi]` 三列组成的子空间矩阵。由于 `xi`/`wi`/`pi` 分散在不同 device 数组中，`gemv` 实际读取的是 `psi_in` 的后续 band，导致子空间更新完全错乱。

**修复**：先用 `syncmem_op` 将 `bv` 的 `adim` 列拷贝到临时连续 device 数组 `d_bv`，再传给 `gemv`。

**效果**：
- GPU `max_error` 从 **13–23** 修复为 **~1e-11**
- 与 CPU 版本精度一致

---

## 3. 全量 Benchmark 数据（单线程 / 单进程）

### 3.1 原始数据

| Solver | npw | nband | sparsity | iterations | time_ms | max_error |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|
| **PPCG CPU** | 100 | 10 | 0 | 200 | 44.4 | 1.18e-11 |
| **PPCG GPU** | 100 | 10 | 0 | 200 | 516.2 | 1.18e-11 |
| **Davidson** | 100 | 10 | 0 | 31 | 8.8 | 1.88e-07 |
| **BPCG** | 100 | 10 | 0 | — | 4.2 | 2.07e-02 |
| **PPCG CPU** | 200 | 20 | 5 | 200 | 189.6 | 1.09e-11 |
| **PPCG GPU** | 200 | 20 | 5 | 200 | 964.8 | 1.09e-11 |
| **Davidson** | 200 | 20 | 5 | 32 | 26.1 | 1.45e-07 |
| **BPCG** | 200 | 20 | 5 | — | 12.3 | 1.17e-02 |
| **PPCG CPU** | 500 | 50 | 6 | 200 | 2278.0 | 1.61e-11 |
| **PPCG GPU** | 500 | 50 | 6 | 200 | 2264.9 | 1.61e-11 |
| **Davidson** | 500 | 50 | 6 | 28 | 295.7 | 2.79e-07 |
| **BPCG** | 500 | 50 | 6 | — | 165.3 | 2.29e-02 |
| **PPCG CPU** | 1000 | 100 | 8 | 200 | 17685.5 | 3.05e-11 |
| **PPCG GPU** | 1000 | 100 | 8 | 200 | 5945.9 | 3.05e-11 |
| **Davidson** | 1000 | 100 | 8 | 31 | 2210.5 | 8.99e-08 |
| **BPCG** | 1000 | 100 | 8 | — | 1282.5 | 2.02e-02 |

### 3.2 速度对比表

| npw | nband | sparsity | PPCG CPU | PPCG GPU | GPU 加速 | David | BPCG |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| 100 | 10 | 0 | 44.4 ms | 516 ms | **0.09×** | 8.8 ms | **4.2 ms** |
| 200 | 20 | 5 | 189.6 ms | 965 ms | **0.20×** | 26.1 ms | **12.3 ms** |
| 500 | 50 | 6 | 2278 ms | 2265 ms | **1.01×** | 296 ms | **165 ms** |
| 1000 | 100 | 8 | 17686 ms | 5946 ms | **2.97×** | 2211 ms | **1283 ms** |

### 3.3 精度对比表

| Solver | 100×10 | 200×20 | 500×50 | 1000×100 |
|:---|:---:|:---:|:---:|:---:|
| **PPCG** | 1.18e-11 | 1.09e-11 | 1.61e-11 | 3.05e-11 |
| **Davidson** | 1.88e-07 | 1.45e-07 | 2.79e-07 | 8.99e-08 |
| **BPCG** | 2.07e-02 | 1.17e-02 | 2.29e-02 | 2.02e-02 |

**精度排序**：PPCG (~1e-11) > Davidson (~1e-7) > BPCG (~1e-2)

---

## 4. 误差分析

### 4.1 各 solver 的误差来源

| Solver | 理论误差 | 实测误差 | 分析 |
|:---|:---|:---|:---|
| **PPCG** | 与 LAPACK 参考值对比 | ~1e-11 | 达到机器精度级别。PPCG 通过子空间 Rayleigh-Ritz 逐步逼近精确特征值，收敛后误差仅受浮点舍入限制。 |
| **Davidson** | 与 LAPACK 参考值对比 | ~1e-7 | 收敛容差 `ethr=1e-7` 即为停止条件，实测误差与容差同量级，符合预期。 |
| **BPCG** | 与 LAPACK 参考值对比 | ~2e-2 | BPCG 的 `diag()` 返回 `void`，无显式误差控制。`max_error=0.02` 说明其内部收敛标准较宽松，或算法本身精度有限。 |

### 4.2 PPCG 收敛行为

- **迭代数**：所有规模下 PPCG 均达到 `PW_DIAG_NMAX=200` 上限，未提前收敛。
- **误差趋势**：`final_err[0]` 从 iter=0 的 ~4 缓慢下降到 iter=200 的 ~1e-7（仍未满足 `ethr=1e-7`）。
- **结论**：PPCG 收敛速度显著慢于 Davidson（~30 次迭代），这是算法本身特性（块预处理共轭梯度 vs Davidson 子空间扩展）。

### 4.3 GPU 与 CPU 数值一致性

修复后，GPU 与 CPU 的 `max_error` 在所有规模下**完全一致**（差异 < 1%），证明：
- cuBLAS 的 `gemm`/`gemv` 数值精度与 OpenBLAS 相当
- Device 内存拷贝和同步逻辑正确

---

## 5. 性能分析

### 5.1 绝对速度排名（1000×100 规模）

1. **BPCG**: 1283 ms（最快，但精度最低）
2. **Davidson**: 2211 ms（速度+精度平衡最佳）
3. **PPCG GPU**: 5946 ms（精度最高，GPU 加速有效）
4. **PPCG CPU**: 17686 ms（最慢，但精度最高）

### 5.2 GPU 加速效果

| 规模 | CPU→GPU 加速 | 分析 |
|:---|:---:|:---|
| 100×10 | **0.09×** | 小规模数据搬运和 kernel launch 开销占主导，GPU 反而慢。 |
| 200×20 | **0.20×** | 矩阵规模仍较小，GPU 并行优势未充分发挥。 |
| 500×50 | **1.01×** | 临界点。计算量足够大，刚好抵消 overhead。 |
| 1000×100 | **2.97×** | 大规模下 GPU 显著领先，加速接近 3 倍。 |

> **预期**：在更大规模（如 2000×200）或更多 GPU（多卡 / H100）上，加速比可进一步提升至 **5–10×**。

### 5.3 PPCG 的迭代效率问题

PPCG 需要 **200 次迭代**，而 Davidson 只需 **~30 次**。即使 GPU 将单次迭代时间缩短，总耗时仍高于 Davidson：

- 1000×100: PPCG GPU 5946 ms vs Davidson 2211 ms → Davidson 仍快 **2.7×**
- 这表明 **PPCG 的瓶颈是算法收敛速度，而非硬件算力**。

---

## 6. 运行命令

### 6.1 编译

```bash
conda activate abacus
export PATH=/usr/bin:/bin:/usr/local/bin:$HOME/.local/bin:$CONDA_PREFIX/bin

cd abacus-develop/build
cmake .. \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++ \
  -DCMAKE_C_COMPILER=/usr/bin/gcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++ \
  -DUSE_CUDA=ON -DENABLE_MPI=ON -DBUILD_TESTING=ON \
  -DUSE_ELPA=OFF -DENABLE_LCAO=OFF

make -j$(nproc) MODULE_HSOLVER_ppcg_bench MODULE_HSOLVER_ppcg_bench_cuda \
  MODULE_HSOLVER_bpcg_bench MODULE_HSOLVER_david_bench
```

### 6.2 运行测试

```bash
cd abacus-test-bench
export OMP_NUM_THREADS=1

# PPCG CPU
./bench_ppcg.sh ppcg_cpu.csv

# PPCG GPU
./bench_ppcg_cuda.sh ppcg_gpu.csv

# BPCG / Davidson
./bench_ppcg.sh --algo bpcg bpcg.csv
./bench_ppcg.sh --algo david david.csv

# 对比
python3 compare_benchmarks.py
```

---

## 7. 代码改动摘要

| 文件 | 改动 |
|:---|:---|
| `abacus-develop/source/source_hsolver/diago_ppcg.cpp` | **修复** `update_vectors_from_ppcg_subspace`：`bv` 列向量不连续，先拷贝到临时 device 数组再传给 `gemv` |
| `abacus-develop/source/source_hsolver/diago_ppcg.h` | **修改** 补充 `#include <ATen/core/tensor.h>`（修复 `ct` 未声明） |
| `abacus-develop/source/source_hsolver/test/CMakeLists.txt` | **修改** 添加 `MODULE_HSOLVER_ppcg_bench_cuda` 编译目标 |
| `abacus-develop/source/source_hsolver/test/diago_ppcg_bench_cuda.cpp` | **新增** GPU benchmark |
| `abacus-test-bench/ppcg_bench_cuda.cpp` | **新增** 独立 GPU benchmark |
| `abacus-test-bench/bench_ppcg_cuda.sh` | **新增** 一键测试脚本 |
| `abacus-test-bench/compare_benchmarks.py` | **新增** 自动对比脚本 |

---

*报告生成时间: 2026-05-30*
