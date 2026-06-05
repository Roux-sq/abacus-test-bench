# OpenMP 效率测试工具

本目录包含 ABACUS 特征值求解器 OpenMP 并行化的效率测试脚本，兼容 `feat/openmp_opt` 和 `feat/openmp_v2` 两个分支。

## 文件说明

| 文件 | 用途 |
|------|------|
| `bench_openmp.sh` | 核心 benchmark 脚本，测试单分支的求解器性能 |
| `compare_branches.sh` | 分支对比脚本，在两个分支间自动切换/编译/测试/对比 |
| `README.md` | 本文件 |

## 快速开始

### 1. 编译（一次性）

```bash
# 进入 abacus-develop，确保位于目标分支
cd /root/homework/abacus-group-project/abacus-develop
git checkout feat/openmp_v2  # 或 feat/openmp_opt

# 一键编译所有 benchmark 目标
cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DUSE_OPENMP=ON
cmake --build build -j$(nproc) --target \
  MODULE_HSOLVER_ppcg_bench \
  MODULE_HSOLVER_bpcg_bench \
  MODULE_HSOLVER_david_bench
```

### 2. 快速验证（小矩阵，~30 秒）

```bash
cd benchmark/openmp_test
./bench_openmp.sh --quick --no-build
```

### 3. 完整 benchmark（中等矩阵）

```bash
./bench_openmp.sh --medium --threads "1 2 4 8"
```

### 4. 大规模 scaling 测试

```bash
./bench_openmp.sh --full --algo bpcg --threads "1 2 4 8 16"
```

### 5. 分支对比

```bash
# 自动在两个分支间切换、编译、运行、对比
./compare_branches.sh --quick
```

## bench_openmp.sh 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--algo A` | `all` | 算法：`ppcg` / `bpcg` / `david` / `all` |
| `--quick` | — | 小矩阵快速验证（2 个配置） |
| `--medium` | ✓ | 中等矩阵（4 个配置） |
| `--full` | — | 大矩阵 scaling（5 个配置） |
| `--threads "1 2 4"` | `"1 2 4"` | OMP_NUM_THREADS 列表 |
| `--build-dir PATH` | `../abacus-develop/build` | 编译目录 |
| `--output-dir PATH` | `./results` | 结果输出目录 |
| `--timeout SEC` | `300` | 单次运行超时（秒） |
| `--no-build` | — | 跳过编译（已编译时用） |
| `--mpi-procs N` | `1` | MPI 进程数 |

## compare_branches.sh 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--base BRANCH` | `feat/openmp_opt` | 基线分支 |
| `--target BRANCH` | `feat/openmp_v2` | 对比分支 |
| `--quick` | — | 快速模式 |
| `--medium` | ✓ | 中等模式 |
| `--algo A` | `all` | 算法选择 |
| `--threads "1 2 4"` | `"1 2 4"` | 线程数列表 |
| `--repo PATH` | `../abacus-develop` | 仓库路径 |

**注意：** `compare_branches.sh` 会自动 stash 当前修改、切换分支、编译、运行、恢复。确保工作区没有重要未保存的改动。

## 输出格式

### BPCG CSV
```
npw,nband,sparsity,mpi_procs,omp_threads,time_ms,max_error
```

### PPCG / Davidson CSV
```
npw,nband,sparsity,mpi_procs,omp_threads,iterations,time_ms,max_error
```

### 对比报告 (comparison_report.txt)
```
=== ABACUS OpenMP Branch Comparison ===
Base branch:   feat/openmp_opt (fb4d7e2)
Target branch: feat/openmp_v2 (abc1234)

Config                         OMP  Base(ms)  Target(ms)  Speedup
200/10/s0                       1    120.5      118.3      1.02x
200/10/s0                       2     65.2       63.1      1.03x
...
```

## 测试矩阵说明

| 模式 | 配置数 | 典型耗时 | 用途 |
|------|--------|---------|------|
| `--quick` | 2 | ~30 秒 | CI 快速验证、代码正确性 |
| `--medium` | 4 | ~3 分钟 | 日常开发调优 |
| `--full` | 5 | ~30 分钟 | 正式性能分析、scaling 研究 |

## 兼容性

- ✅ `feat/openmp_opt` — 原始 OpenMP 实现
- ✅ `feat/openmp_v2` — 修复后的 OpenMP 实现（包含 `vector<bool>` → `vector<char>` 等修复）
- ✅ 自动检测 `mpirun` 位置
- ✅ 自动适配 PPCG/BPCG/Davidson 不同的输出列
- ✅ 支持 MPI 和纯串行两种运行模式
