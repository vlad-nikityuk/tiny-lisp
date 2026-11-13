#!/usr/bin/env python3
"""Runs every bench/py/NAME.py and bench/NAME.lisp from the repo root, checks that they print the same, and compares the
best-of-N wall times (the whole process, interpreter start included).
Usage: python3 bench/run.py [-n RUNS] [--binary PATH] [name ...]"""
import argparse, glob, math, os, subprocess, sys, time


def run(cmd):
    t = time.perf_counter()
    p = subprocess.run(cmd, capture_output=True, text=True)
    return time.perf_counter() - t, p.stdout, p.returncode, p.stderr


def best(cmd, runs):
    times, expected = [], None
    for _ in range(runs):
        t, out, code, err = run(cmd)
        times.append(t)
        if code:
            return min(times), out, code, err
        if expected is not None and out != expected:
            return min(times), out, 1, "inconsistent output between repetitions"
        expected = out
    return min(times), expected, 0, ""


def positive_int(value):
    n = int(value)
    if n <= 0:
        raise argparse.ArgumentTypeError("runs must be positive")
    return n


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-n", type=positive_int, default=3, dest="runs")
    parser.add_argument("--binary", default="./tinylisp")
    parser.add_argument("names", nargs="*")
    args = parser.parse_args()
    runs = args.runs
    binary = os.path.abspath(args.binary)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    names = args.names or sorted(os.path.basename(p)[:-5] for p in glob.glob("bench/*.lisp") if not p.endswith("prelude.lisp"))
    empty_py, _, cp, ep = best([sys.executable, "-c", "pass"], runs)
    empty_tl, _, cl, el = best([binary, "-f", "/dev/null"], runs)
    if cp or cl:
        print(f"startup FAILED python:{cp} tinylisp:{cl} {ep or el}", file=sys.stderr)
        return 1
    print(f"{'benchmark':<16}{'python':>9}{'tinylisp':>10}{'ratio':>8}  output")
    print(f"{'(startup)':<16}{empty_py:>8.3f}s{empty_tl:>9.3f}s")
    ratios = []
    failed = False
    for name in names:
        tp, op, cp, ep = best([sys.executable, f"bench/py/{name}.py"], runs)
        tl, ol, cl, el = best([binary, "-f", f"bench/{name}.lisp"], runs)
        if cp or cl:
            status = f"FAILED python:{cp} tinylisp:{cl} {(ep or el).strip().splitlines()[-1:]}"
        elif op.split() != ol.split():
            status = f"DIFFERENT: python {op.split()[:6]} tinylisp {ol.split()[:6]}"
        else:
            status = "same"
            ratios.append(tl / tp)
        failed |= status != "same"
        print(f"{name:<16}{tp:>8.3f}s{tl:>9.3f}s{tl / tp:>7.2f}x  {status}", flush=True)
    if ratios:
        print(f"geometric mean of tinylisp/python over the {len(ratios)} that agree: {math.exp(sum(map(math.log, ratios)) / len(ratios)):.2f}x")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
