# ABACUS PPCG 真实场景可靠性测试

本目录包含使用 ABACUS 官方算例集 (`abacus-user-guide/examples/pw/`) 测试 PPCG 特征值求解器可靠性的自动化脚本，
支持将 PPCG 与 CG、BPCG、David、dav_subspace 等求解器进行正确性和性能对比。

## 目录结构

```
real-scenario/
├── README.md           ← 本文件
├── run_single.sh       ← 对单个算例运行指定求解器
├── run_compare.sh      ← 对一个算例运行所有求解器并汇总结果
├── run_all.sh          ← 对所有算例运行所有求解器
├── parse_log.py        ← 从 ABACUS 输出中提取关键数据
└── results/            ← 运行结果输出目录
    ├── logs/           ← 每次运行的完整日志
    └── summary.csv     ← 汇总表
```

## 前置条件

### 1. 获取官方算例集

请在 `abacus-test-bench` 的同级目录下执行 `git clone https://gitee.com/mcresearch/abacus-user-guide.git` 获取官方算例集.

### 2. 编译 ABACUS

```bash
cd abacus-develop
cmake -B build -DBUILD_TESTING=ON -DENABLE_MPI=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

编译成功后，二进制文件位于 `build/abacus`（或 `build/abacus_basic_para`）。

**重要**：PPCG 在 `feature/eigen-solver-optimization` 分支上，编译前请确认在该分支上。

### 3. 使脚本可执行

```bash
cd benchmark/real-scenario
chmod +x run_single.sh run_compare.sh run_all.sh
```

### 4. 安装 Python 3（用于 parse_log.py）

```bash
python3 --version  # 确认可用
```

### 5. 确认算例目录存在

```bash
ls abacus-user-guide/examples/pw/
# 应看到 001_4GaAs ~ 010_216Si 共 10 个子目录
```

## 快速开始

### 第一步：验证编译和单元测试

```bash
# 运行 PPCG 单元测试
cd abacus-develop
mpirun -np 1 ./build/source/source_hsolver/test/MODULE_HSOLVER_ppcg
```

### 第二步：快速验证（单个算例，单求解器）

```bash
cd benchmark/real-scenario

# 用 4 个 MPI 进程测试 PPCG 在 GaAs 算例上的表现
./run_single.sh \
    --solver ppcg \
    --np 4 \
    --example ../../abacus-user-guide/examples/pw/001_4GaAs \
    --binary ../../abacus-develop/build/abacus
```

### 第三步：单算例多求解器对比

```bash
# 对 GaAs 算例运行全部 5 种求解器并对比
./run_compare.sh \
    --solvers cg,bpcg,ppcg,dav,dav_subspace \
    --np 4 \
    --example ../../abacus-user-guide/examples/pw/001_4GaAs
```

### 第四步：批量运行（快速模式，仅前 3 个算例）

```bash
# 快速模式：只跑 001~003 三个最小的算例
./run_all.sh --solvers cg,bpcg,ppcg --np 4 --quick
```

### 第五步：全量运行（需较长时间）

```bash
# 完整模式：10 个算例 × 3 种求解器
./run_all.sh --solvers cg,bpcg,ppcg --np 4
```

## 脚本详细说明

### run_single.sh

对**一个算例**运行**一种求解器**，输出关键数据。

```bash
./run_single.sh [OPTIONS]

选项：
  --solver NAME    特征值求解器（必需）：cg, bpcg, ppcg, dav, dav_subspace
  --np N           MPI 进程数（必需）
  --example DIR    算例目录路径（必需）
  --binary PATH    ABACUS 二进制文件路径（默认：../../abacus-develop/build/abacus）
  --omp N          OpenMP 线程数（默认：1）
  --output-dir DIR 结果输出目录（默认：./results）
```

输出示例：
```
=== PPCG on 001_4GaAs ===
Solver:       ppcg
Total energy: -7836.71717 eV
SCF steps:    8
Wall time:    45.2s
PPCG iters:   avg=42.3, max=58, min=31
Locked ratio: 85%
```

### run_compare.sh

对**一个算例**依次运行**多种求解器**，输出对比表格。

```bash
./run_compare.sh [OPTIONS]

选项：
  --solvers LIST  逗号分隔的求解器列表（默认：cg,bpcg,ppcg,dav,dav_subspace）
  --np N          MPI 进程数（必需）
  --example DIR   算例目录路径（必需）
  --binary PATH   ABACUS 二进制文件路径
  --output-dir DIR 结果输出目录
```

输出示例：
```
=== Solver Comparison: 001_4GaAs ===
| Solver       | Total Energy (eV) | ΔE vs CG (eV) | SCF Steps | Wall Time | Notes          |
|-------------|--------------------|---------------|-----------|-----------|----------------|
| cg          | -7836.717178       | 0.000000      | 8         | 32.1s     | baseline       |
| bpcg        | -7836.717180       | -0.000002     | 8         | 35.4s     |                |
| ppcg        | -7836.717177       | +0.000001     | 8         | 45.2s     | avg_iter=42.3  |
| dav         | -7836.717179       | -0.000001     | 8         | 33.8s     |                |
| dav_subspace| -7836.717178       | 0.000000      | 8         | 30.5s     |                |
```

### run_all.sh

对所有 10 个算例批量运行，输出 CSV 汇总表。

```bash
./run_all.sh [OPTIONS]

选项：
  --solvers LIST  逗号分隔的求解器列表（默认：cg,bpcg,ppcg）
  --np N          MPI 进程数（必需）
  --quick         快速模式：仅运行前 3 个算例
  --binary PATH   ABACUS 二进制文件路径
  --output-dir DIR 结果输出目录
```

### parse_log.py

独立的日志解析工具，也可单独使用：

```bash
# 解析单次运行的输出
python3 parse_log.py --log results/logs/001_4GaAs_ppcg.log --solver ppcg
```

支持解析：
- 总能量 (`ETOT`)
- SCF 收敛步数
- PPCG 对角化迭代次数和锁定信息
- 各 SCF 步的时间和能量变化

## 结果验证

### 正确性判断标准

- **合格**：求解器间总能量差异 < 1e-4 eV/atom
- **良好**：求解器间总能量差异 < 1e-6 eV/atom
- **参考值**：见 `abacus-user-guide/test-10cases.md`，基于 ABACUS v3.9.0.19 + 28 核

### 性能对比关注点

| 指标 | 说明 |
|------|------|
| 总 wall time | SCF 全部迭代的总耗时 |
| SCF 收敛步数 | 不同求解器可能导致不同收敛速度 |
| PPCG 内迭代 | 每步 SCF 中 PPCG 对角化的迭代次数 |
| 锁定比例 | PPCG 提前收敛锁定的波段占比 |

## 10 个算例概览

| 序号 | 目录 | 体系 | 原子数 | 能带数 | 参考总能量 (eV) |
|------|------|------|--------|--------|-----------------|
| 1 | 001_4GaAs | GaAs 半导体 | 8 | 46 | -7836.71715 |
| 2 | 002_C2H6O | 乙醇分子 | 9 | 20 | -671.05736 |
| 3 | 003_4MoS2 | MoS2 二维 | 12 | 62 | -9705.23391 |
| 4 | 004_12Pt111 | Pt(111) 表面 | 12 | 129 | -39606.62899 |
| 5 | 005_3BaTiO3 | 钙钛矿 | 15 | 72 | -10751.59178 |
| 6 | 006_16Na | Na 金属 | 16 | 86 | -18526.84275 |
| 7 | 007_27Fe | Fe 铁磁 | 27 | 286 | -86954.62020 |
| 8 | 008_32H2O | 液态水 | 96 | 128 | -14954.91552 |
| 9 | 009_Li27Ni9O54Mn9Co9 | 电池阴极 | 108 | 490 | -124083.44987 |
| 10 | 010_216Si | Si 半导体 | 216 | 518 | -23161.83012 |

## 工作原理

### 脚本如何运行

1. `run_single.sh` 在 `results/` 下创建临时工作目录
2. 将原始算例的 `INPUT` 复制过来，修改 `ks_solver` 为目标求解器
3. 创建指向原始 `STRU`、`KPT`、赝势文件的软链接（避免复制大文件）
4. 运行 `mpirun -np N /path/to/abacus`，stdout 和 stderr 分别捕获
5. 从 `OUT.autotest/running_scf.log` 提取总能量和 SCF 步数
6. 从 stderr 提取 PPCG 诊断信息（迭代次数、锁定状态）
7. 清理临时目录，日志保留在 `results/logs/`

### PPCG 诊断输出解读

PPCG 每 10 轮迭代向 stderr 输出一行：

```
[PPCG] iter=10 err[0]=0.354 err[end]=0.466 ethr=1e-07 locked=0/10 blocked=no
```

- `iter`: 当前 PPCG 迭代号
- `err[0]` / `err[end]`: 第一个/最后一个未锁定波段的残差范数
- `ethr`: 收敛阈值（与 `scf_thr` 不同，由 ABACUS 内部计算）
- `locked`: 已收敛锁定的波段数 / 总波段数（extra bands 不计入）
- `blocked`: 是否使用分块对角阵模式（`set_block_sizes` 启用）

收敛完成时输出：
```
[PPCG] done: niter=42 final_err[0]=1.2e-11 final_err[end]=3.4e-07 eigen[0]=-5.678
```

- `niter`: 总迭代次数
- `final_err`: 最终残差
- `eigen[0]`: 最小特征值（基态能量）

## 故障排查

### "ks_solver = ppcg not recognized"
→ ABACUS 版本过旧，请确认在 `feature/eigen-solver-optimization` 分支上编译

### "DiagoPPCG falls back to BPCG on GPU"
→ PPCG 不支持 GPU，请使用 CPU-only 编译（不要设置 `-DUSE_CUDA=ON`）

### MPI 相关错误
→ 确认 `mpirun` 可用：`which mpirun`，检查 `--np` 不超过机器核心数

### 算例运行失败（段错误等）
→ 尝试减少 `--np`，或用 `--quick` 先从最小算例开始排查。也可先做 dry-run：
```bash
./run_single.sh --solver ppcg --np 1 --example ... --dry-run
```

### 结果文件为空或只有 header
→ 检查 stderr 错误日志：`cat results/logs/001_4GaAs_ppcg.err`
