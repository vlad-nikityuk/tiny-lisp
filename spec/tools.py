#!/usr/bin/env python3
"""Regression checks for the benchmark and REPL validation tools."""
import importlib.util, subprocess, sys, runpy, contextlib, io
from unittest.mock import patch

binary = sys.argv[1]
spec = importlib.util.spec_from_file_location("bench_run", "bench/run.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
for runs in [
    [(0.1, "ok", 1, "failed"), (0.2, "ok", 0, "")],
    [(0.1, "first", 0, ""), (0.2, "second", 0, "")],
]:
    with patch.object(bench, "run", side_effect=runs):
        assert bench.best(["fake"], 2)[2] != 0
with patch.object(bench, "run", return_value=(0.1, "ok", 0, "")):
    assert bench.best(["fake"], 2) == (0.1, "ok", 0, "")
for arg in ["0", "-1"]:
    assert subprocess.run([sys.executable, "bench/run.py", "-n", arg], capture_output=True).returncode != 0
for results in [
    [(0.1, "", 0, ""), (0.1, "", 0, ""), (0.1, "a", 0, ""), (0.1, "b", 0, "")],
    [(0.1, "", 0, ""), (0.1, "", 0, ""), (0.1, "", 2, "failed"), (0.1, "", 0, "")],
]:
    with patch.object(sys, "argv", ["bench/run.py", "-n", "1", "fake"]), patch.object(bench, "best", side_effect=results), contextlib.redirect_stdout(io.StringIO()):
        assert bench.main() == 1
# Capture the actual valid REPL transcript, then exercise each harness failure.
real_run = subprocess.run
captured = []
def record(*args, **kwargs):
    result = real_run(*args, **kwargs)
    captured.append(result)
    return result
with patch.object(sys, "argv", ["spec/repl.py", binary]), patch.object(subprocess, "run", side_effect=record), contextlib.redirect_stdout(io.StringIO()):
    try:
        runpy.run_path("spec/repl.py", run_name="__main__")
    except SystemExit as e:
        assert e.code == 0
valid = captured[0]
for output, code in [(valid.stdout, 1), ("", 0), (valid.stdout + "\x1b[32mextra\x1b[39m", 0)]:
    fake = subprocess.CompletedProcess([], code, output, "")
    with patch.object(sys, "argv", ["spec/repl.py", "fake"]), patch.object(subprocess, "run", return_value=fake), contextlib.redirect_stdout(io.StringIO()):
        try:
            runpy.run_path("spec/repl.py", run_name="__main__")
        except SystemExit as e:
            assert e.code == 1
print("Harness failure checks passed")
