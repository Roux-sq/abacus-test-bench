#!/usr/bin/env python3
"""
parse_log.py — Parse ABACUS output logs to extract key metrics.

Can parse:
  - SCF convergence log (OUT.autotest/running_scf.log)
  - PPCG stderr diagnostic output ([PPCG] iter=... lines)
  - General solver timing information

Usage:
  python3 parse_log.py --log results/logs/001_4GaAs_ppcg.log [--solver ppcg]
  python3 parse_log.py --scf-log OUT.autotest/running_scf.log
  python3 parse_log.py --ppcg-log results/logs/001_4GaAs_ppcg.err

Outputs JSON with extracted metrics.
"""

import argparse
import json
import re
import sys
from pathlib import Path


def parse_scf_log(filepath: str) -> dict:
    """Parse running_scf.log to extract SCF iteration data."""
    result = {
        "scf_steps": 0,
        "final_energy": None,
        "final_energy_per_atom": None,
        "converged": False,
        "iterations": [],
    }

    if not Path(filepath).exists():
        result["error"] = f"File not found: {filepath}"
        return result

    with open(filepath, "r") as f:
        lines = f.readlines()

    # Pattern 1: standard ABACUS SCF output like:
    #   ITER   ETOT(eV)       EDIFF(eV)      DRHO       TIME(s)
    #   CG1    -7.83583788e+03 0.00000000e+00 2.5736e-01 12.72
    #   CG2    -7.83662393e+03 -7.86047670e-01 1.8579e-02 2.10
    scf_pattern = re.compile(
        r'^\s*(?:CG|DAV|BPCG|PPCG)?\s*(\d+)\s+'  # iteration number
        r'([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)\s+'   # ETOT
        r'([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)\s+'   # EDIFF
        r'([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)\s+'   # DRHO
        r'([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)'      # TIME
    )

    # Pattern 2: some versions use different format
    alt_pattern = re.compile(
        r'^\s*ITER\s+ETOT'
    )

    for line in lines:
        m = scf_pattern.match(line.strip())
        if m:
            iter_data = {
                "iter": int(m.group(1)),
                "etot": float(m.group(2)),
                "ediff": float(m.group(3)),
                "drho": float(m.group(4)),
                "time_s": float(m.group(5)),
            }
            result["iterations"].append(iter_data)

    if result["iterations"]:
        result["scf_steps"] = len(result["iterations"])
        result["final_energy"] = result["iterations"][-1]["etot"]
        result["converged"] = abs(result["iterations"][-1]["ediff"]) < 1e-6

    # Fallback: look for "FINAL_ETOC_IS" or "TOTAL-ENERGY"
    if result["final_energy"] is None:
        for line in lines:
            m = re.search(r'(?:FINAL_ETOT|TOTAL.ENERGY)\s*[=:]\s*([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)', line)
            if m:
                result["final_energy"] = float(m.group(1))
                break

    # Fallback: look for "convergence has been achieved" or "SCF loop end"
    for line in lines:
        if re.search(r'convergence\s+(?:has been\s+)?achieved|SCF\s+loop\s+end|charge\s+density\s+converged', line, re.IGNORECASE):
            result["converged"] = True
            break

    return result


def parse_ppcg_stderr(filepath: str) -> dict:
    """Parse PPCG diagnostic output from stderr."""
    result = {
        "ppcg_runs": [],
        "total_ppcg_iters": 0,
        "min_iters": None,
        "max_iters": None,
        "avg_iters": None,
        "final_locked": None,
    }

    if not Path(filepath).exists():
        result["error"] = f"File not found: {filepath}"
        return result

    with open(filepath, "r") as f:
        lines = f.readlines()

    # [PPCG] iter=10 err[0]=0.354 err[end]=0.466 ethr=1e-07 locked=0/10 blocked=no
    iter_pattern = re.compile(
        r'\[PPCG\]\s+iter=(\d+)\s+'
        r'err\[0\]=([\d.eE+-]+)\s+'
        r'err\[end\]=([\d.eE+-]+)\s+'
        r'ethr=([\d.eE+-]+)\s+'
        r'locked=(\d+)/(\d+)\s+'
        r'blocked=(yes|no)'
    )

    # [PPCG] done: niter=42 final_err[0]=1.2e-11 final_err[end]=3.4e-07 eigen[0]=-5.678
    done_pattern = re.compile(
        r'\[PPCG\]\s+done:\s+niter=(\d+)\s+'
        r'final_err\[0\]=([\d.eE+-]+)\s+'
        r'final_err\[end\]=([\d.eE+-]+)\s+'
        r'eigen\[0\]=([\d.eE+-]+)'
    )

    current_run = None

    for line in lines:
        # Start of a new PPCG run
        if "[PPCG] iter=0" in line:
            if current_run is not None:
                result["ppcg_runs"].append(current_run)
            current_run = {"iterations": [], "done": None}

        # Iteration line
        m = iter_pattern.search(line)
        if m and current_run is not None:
            current_run["iterations"].append({
                "iter": int(m.group(1)),
                "err_first": float(m.group(2)),
                "err_last": float(m.group(3)),
                "ethr": float(m.group(4)),
                "locked": f"{m.group(5)}/{m.group(6)}",
                "n_locked": int(m.group(5)),
                "n_total": int(m.group(6)),
                "blocked": m.group(7) == "yes",
            })

        # Done line
        m = done_pattern.search(line)
        if m and current_run is not None:
            current_run["done"] = {
                "niter": int(m.group(1)),
                "final_err_first": float(m.group(2)),
                "final_err_last": float(m.group(3)),
                "eigen_first": float(m.group(4)),
            }

    if current_run is not None:
        result["ppcg_runs"].append(current_run)

    # Compute aggregate statistics
    niters = [run["done"]["niter"] for run in result["ppcg_runs"] if run.get("done")]
    if niters:
        result["total_ppcg_iters"] = sum(niters)
        result["min_iters"] = min(niters)
        result["max_iters"] = max(niters)
        result["avg_iters"] = sum(niters) / len(niters)

    # Last locking ratio
    last_locked = None
    for run in result["ppcg_runs"]:
        if run.get("iterations"):
            last_locked = run["iterations"][-1].get("locked")
    if last_locked:
        result["final_locked"] = last_locked

    return result


def parse_main_log(filepath: str) -> dict:
    """Parse the main ABACUS output log (stdout)."""
    result = {
        "total_wall_time_s": None,
        "init_time_s": None,
        "scf_time_s": None,
        "diago_ppcg_time_s": None,
        "start_time": None,
        "end_time": None,
        "abacus_version": None,
        "warnings": [],
    }

    if not Path(filepath).exists():
        result["error"] = f"File not found: {filepath}"
        return result

    with open(filepath, "r") as f:
        text = f.read()
        lines = text.split("\n")

    # Wall time
    m = re.search(r'(?:TOTAL|WALL).*?TIME\s*[=:]\s*([\d.]+)\s*(?:s|sec|seconds)?', text, re.IGNORECASE)
    if m:
        result["total_wall_time_s"] = float(m.group(1))

    # ABACUS version line
    for line in lines[:20]:
        m = re.search(r'(?:ABACUS|version|v\d+\.\d+)', line, re.IGNORECASE)
        if m:
            result["abacus_version"] = line.strip()
            break

    # Timer output: "CLASS_NAME  |  NAME  |  TIME(s)  |  CALLS"
    timer_section = False
    for line in lines:
        if "CLASS_NAME" in line and "TIME" in line:
            timer_section = True
            continue
        if timer_section:
            m = re.match(r'^\s*(\S+)\s+\|\s+(\S+)\s+\|\s+([\d.]+)', line)
            if m:
                class_name, name, time_val = m.group(1), m.group(2), float(m.group(3))
                if class_name == "DiagoPPCG" and name == "diag":
                    result["diago_ppcg_time_s"] = time_val
                if class_name == "Driver" and name in ("driver_run", "run"):
                    result["scf_time_s"] = time_val
            else:
                timer_section = False

    # Warnings
    for line in lines:
        if re.search(r'WARNING|WARN', line):
            result["warnings"].append(line.strip())

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Parse ABACUS output logs to extract key metrics."
    )
    parser.add_argument("--log", help="Path to main ABACUS stdout log")
    parser.add_argument("--scf-log", help="Path to running_scf.log")
    parser.add_argument("--ppcg-log", help="Path to PPCG stderr log")
    parser.add_argument("--solver", default=None, help="Solver name (for context)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--summary", action="store_true", help="Output a one-line summary")

    args = parser.parse_args()

    result = {"solver": args.solver}

    if args.log:
        result["main"] = parse_main_log(args.log)

    if args.scf_log:
        result["scf"] = parse_scf_log(args.scf_log)

    if args.ppcg_log:
        result["ppcg"] = parse_ppcg_stderr(args.ppcg_log)

    if args.summary:
        scf = result.get("scf", {})
        ppcg = result.get("ppcg", {})
        parts = [
            f"solver={args.solver or '?'}",
            f"energy={scf.get('final_energy', 'N/A')}",
            f"scf_steps={scf.get('scf_steps', 'N/A')}",
            f"converged={scf.get('converged', 'N/A')}",
        ]
        if ppcg and "avg_iters" in ppcg:
            parts.append(f"ppcg_avg_iters={ppcg['avg_iters']:.1f}")
            parts.append(f"ppcg_final_locked={ppcg.get('final_locked', 'N/A')}")
        print(" | ".join(parts))
    elif args.json:
        print(json.dumps(result, indent=2, default=str))
    else:
        # Pretty print
        scf = result.get("scf", {})
        ppcg = result.get("ppcg", {})
        main_info = result.get("main", {})

        print(f"=== ABACUS Log Analysis (solver={args.solver or 'unknown'}) ===")
        print()

        if main_info:
            if main_info.get("total_wall_time_s"):
                print(f"Total wall time:  {main_info['total_wall_time_s']:.1f}s")
            if main_info.get("diago_ppcg_time_s"):
                print(f"DiagoPPCG time:   {main_info['diago_ppcg_time_s']:.3f}s")
            if main_info.get("warnings"):
                print(f"Warnings:         {len(main_info['warnings'])}")
            print()

        if scf:
            print(f"SCF steps:        {scf.get('scf_steps', 'N/A')}")
            print(f"Final energy:     {scf.get('final_energy', 'N/A')}")
            print(f"Converged:        {scf.get('converged', 'N/A')}")
            if scf.get("iterations"):
                last = scf["iterations"][-1]
                print(f"Last EDIFF:       {last['ediff']:.2e}")
                print(f"Last DRHO:        {last['drho']:.2e}")
                print(f"Total SCF time:   {sum(it['time_s'] for it in scf['iterations']):.1f}s")
            print()

        if ppcg and "ppcg_runs" in ppcg:
            n_runs = len(ppcg["ppcg_runs"])
            print(f"PPCG runs:        {n_runs}")
            if ppcg.get("avg_iters") is not None:
                print(f"PPCG avg iters:   {ppcg['avg_iters']:.1f}")
                print(f"PPCG min/max:     {ppcg['min_iters']} / {ppcg['max_iters']}")
            if ppcg.get("final_locked"):
                print(f"PPCG final lock:  {ppcg['final_locked']}")
            print()


if __name__ == "__main__":
    main()
