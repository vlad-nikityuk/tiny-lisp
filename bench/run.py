#!/usr/bin/env python3
"""Runs every bench/py/NAME.py and bench/NAME.lisp from the repo root, checks that they print the same, and compares the
best-of-N wall times (the whole process, interpreter start included).
Usage: python3 bench/run.py [-n RUNS] [name ...]"""
import glob, math, os, subprocess, sys, time


def run(cmd):
    t = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True)
    return time.perf_counter() - t, p.stdout, p.returncode, p.stderr


def best(cmd, runs):
    times, out, code, err = [], "", 0, ""
    for _ in range(runs):
        t, out, code, err = run(cmd)
        times.append(t)
    return min(times), out, code, err


def main():
    args = sys.argv[1:]
    runs = 3
    if args[:1] == ["-n"]:
        runs, args = int(args[1]), args[2:]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    names = args or sorted(os.path.basename(p)[:-5] for p in glob.glob("bench/*.lisp") if not p.endswith("prelude.lisp"))
    empty_py = best([sys.executable, "-c", "pass"], runs)[0]
    empty_tl = best(["./tinylisp", "-f", "/dev/null"], runs)[0]
    print(f"{'benchmark':<16}{'python':>9}{'tinylisp':>10}{'ratio':>8}  output")
    print(f"{'(startup)':<16}{empty_py:>8.3f}s{empty_tl:>9.3f}s")
    ratios = []
    for name in names:
        tp, op, cp, ep = best([sys.executable, f"bench/py/{name}.py"], runs)
        tl, ol, cl, el = best(["./tinylisp", "-f", f"bench/{name}.lisp"], runs)
        if cp or cl:
            status = f"FAILED python:{cp} tinylisp:{cl} {(ep or el).strip().splitlines()[-1:]}"
        elif op.split() != ol.split():
            status = f"DIFFERENT: python {op.split()[:6]} tinylisp {ol.split()[:6]}"
        else:
            status = "same"
            ratios.append(tl / tp)
        print(f"{name:<16}{tp:>8.3f}s{tl:>9.3f}s{tl / tp:>7.2f}x  {status}", flush=True)
    if ratios:
        print(f"geometric mean of tinylisp/python over the {len(ratios)} that agree: {math.exp(sum(map(math.log, ratios)) / len(ratios)):.2f}x")


main()
