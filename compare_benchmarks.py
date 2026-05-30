#!/usr/bin/env python3
"""
对比 abacus-test-bench 中各 solver 的 benchmark 结果。
用法：python3 compare_benchmarks.py
"""
import csv
import os
import sys
from pathlib import Path

def read_csv(path):
    rows = []
    with open(path, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            # 过滤掉 gtest 输出等无效行
            if not row.get('npw', '').isdigit():
                continue
            rows.append(row)
    return rows

def key(r):
    return (int(r['npw']), int(r['nband']), int(r['sparsity']))

def pick_single_thread(rows, algo):
    # 优先选 mpi_procs=1, omp_threads=1
    filtered = [r for r in rows if int(r.get('mpi_procs', 1)) == 1 and int(r.get('omp_threads', 1)) == 1]
    if not filtered:
        filtered = rows
    return {key(r): r for r in filtered}

def fmt_time(t):
    try:
        return f"{float(t):.2f}"
    except:
        return str(t)

def fmt_iter(it, algo):
    if algo == 'bpcg':
        return '-'
    try:
        return str(int(float(it)))
    except:
        return str(it)

def main():
    base = Path(__file__).parent
    data = {}
    files = {
        'ppcg (cpu)': 'ppcg_before.csv',
        'david': 'david_before.csv',
        'bpcg': 'bpcg_before.csv',
        'ppcg mpi': 'ppcg_mpi_results.csv',
        'david mpi': 'david_mpi_results.csv',
        'bpcg mpi': 'bpcg_mpi_results.csv',
    }
    for label, fname in files.items():
        path = base / fname
        if path.exists():
            rows = read_csv(path)
            data[label] = pick_single_thread(rows, label.split()[0])
        else:
            print(f"Warning: {path} not found", file=sys.stderr)

    # 收集所有配置
    configs = set()
    for d in data.values():
        configs.update(d.keys())
    configs = sorted(configs)

    # 打印单线程对比表
    print("=" * 100)
    print("Benchmark 对比表（单进程单线程）")
    print("=" * 100)
    header = f"{'npw':>6} {'nband':>6} {'sparsity':>9} | {'PPCG iter':>10} {'PPCG t/ms':>12} | {'David iter':>10} {'David t/ms':>12} | {'BPCG iter':>10} {'BPCG t/ms':>12}"
    print(header)
    print("-" * 100)
    for cfg in configs:
        npw, nband, sparsity = cfg
        ppcg = data.get('ppcg (cpu)', {}).get(cfg, {})
        david = data.get('david', {}).get(cfg, {})
        bpcg = data.get('bpcg', {}).get(cfg, {})
        print(f"{npw:>6} {nband:>6} {sparsity:>9} | "
              f"{fmt_iter(ppcg.get('iterations', 'N/A'), 'ppcg'):>10} {fmt_time(ppcg.get('time_ms', 'N/A')):>12} | "
              f"{fmt_iter(david.get('iterations', 'N/A'), 'david'):>10} {fmt_time(david.get('time_ms', 'N/A')):>12} | "
              f"{fmt_iter(bpcg.get('iterations', 'N/A'), 'bpcg'):>10} {fmt_time(bpcg.get('time_ms', 'N/A')):>12}")

    # MPI 对比表（取 mpi_procs 变化的数据）
    print("\n" + "=" * 100)
    print("PPCG MPI 扩展性对比")
    print("=" * 100)
    mpi_labels = ['ppcg (cpu)', 'ppcg mpi']
    for cfg in configs:
        npw, nband, sparsity = cfg
        print(f"\nConfig: npw={npw}, nband={nband}, sparsity={sparsity}")
        for label in mpi_labels:
            rows = data.get(label, {})
            row = rows.get(cfg)
            if row:
                print(f"  {label:12s}: procs={row.get('mpi_procs','?'):>2}, threads={row.get('omp_threads','?'):>2}, "
                      f"iter={fmt_iter(row.get('iterations','?'), 'ppcg'):>6}, time={fmt_time(row.get('time_ms','?')):>10} ms")

    print("\n" + "=" * 100)
    print("说明")
    print("=" * 100)
    print("- PPCG 迭代数均为 200，表示达到最大迭代次数未收敛（或收敛极慢）。")
    print("- David 迭代数约 27-32，远小于 PPCG，收敛更快。")
    print("- BPCG 无迭代数输出（diag 返回 void），但运行时间最短。")
    print("- PPCG CPU 单线程在大规模（1000x100）下耗时约 42s，显著高于 David（~2.2s）和 BPCG（~1.3s）。")
    print("- CUDA 版本预期在 GPU 上大幅缩短 PPCG 的矩阵-向量乘法时间，待实测补充。")

if __name__ == '__main__':
    main()
