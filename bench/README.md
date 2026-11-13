# Benchmarks: microgpt-like programs in Python and tinylisp

18 small, self-contained, deterministic programs in the spirit of Karpathy's micrograd and microgpt: ML micro-projects
(a scalar-autograd MLP, logistic regression, k-means, a bigram model, byte-pair encoding) and the classic kernels
(n-body, spectral norm, fannkuch, n-queens, Mandelbrot, sieve, game of life, edit distance, knapsack, Dijkstra,
quicksort). Each exists twice, `py/NAME.py` and `NAME.lisp`, written to read side by side, and both print the same
numbers. No imports besides `math`, no numpy. Where the Python comes from is in [py/README.md](py/README.md).

```bash
python3 bench/run.py          # all of them, best of 3
python3 bench/run.py -n 1 nbody life
```

`run.py` runs each program from the repo root, fails the row if the output differs, and times the whole process.

## How the pairs stay comparable

- The same algorithm and the same order of floating-point operations, so the results agree to the last digit; programs
  print integer checksums (`floor(x * 1e6)`), never a float format.
- The same random numbers: both use the stdlib's Park-Miller generator (`rand`), 20240607 as the seed.
- The Python is plain loops and lists, no tricks that hide work in C (no slicing, comprehension, `sort`, `numpy`);
  `sum`, `zip`, `min` and `max` appear where the Lisp uses `sum`, `zip`, `min` and `max`.
- The Lisp uses the repo's own macros: `for`, `for/list`, `->`, `val` (infix autograd), `+=`, `at+=`
  (`bench/prelude.lisp` adds `+=`, `range-step` and the other Python builtins).
- `bench/py/value.py` is micrograd's `Value` with the graph and gradient order of `examples/autograd.lisp`; `__pow__` uses
  `exp` and `log`, because tinylisp has no `pow`.

Where the Lisp cannot copy the Python line for line: a `while` is a tail-recursive function (`fannkuch`, `mandelbrot`,
`sieve`, `bigram` sampling); `bpe` fills a preallocated vector where Python appends; `levenshtein` splits a name into a
list of characters where Python indexes the string.

## Results

Apple M2 Max, Python 3.14.5 (no JIT), tinylisp built with `make` (ReleaseSafe), best of 3 whole-process times.
Interpreter start is 0.021 s for Python and 0.003 s for tinylisp, and is included.

| benchmark | python | tinylisp | tinylisp / python |
|---|---|---|---|
| kmeans | 0.290 s | 0.092 s | 0.32x |
| logreg | 0.355 s | 0.131 s | 0.37x |
| matmul | 0.362 s | 0.133 s | 0.37x |
| dijkstra | 0.343 s | 0.126 s | 0.37x |
| knapsack | 0.386 s | 0.167 s | 0.43x |
| mlp_xor (scalar autograd) | 0.301 s | 0.150 s | 0.50x |
| linreg (scalar autograd) | 0.305 s | 0.155 s | 0.51x |
| mandelbrot | 0.323 s | 0.183 s | 0.57x |
| bpe | 0.304 s | 0.184 s | 0.61x |
| sieve | 0.377 s | 0.291 s | 0.77x |
| spectral_norm | 0.272 s | 0.245 s | 0.90x |
| nbody | 0.362 s | 0.346 s | 0.95x |
| quicksort | 0.195 s | 0.191 s | 0.98x |
| life | 0.342 s | 0.346 s | 1.01x |
| bigram | 0.143 s | 0.147 s | 1.03x |
| levenshtein | 0.199 s | 0.226 s | 1.13x |
| nqueens | 0.396 s | 0.480 s | 1.21x |
| fannkuch | 0.410 s | 0.553 s | 1.35x |

Geometric mean: tinylisp takes 0.67x as long as CPython 3.14 (it was 2.4x before the second tier below).

## What the numbers say

- **The evaluator has two tiers.** The first call of a function compiles its body to a stack bytecode with fixed slots for its
  parameters and defines (`src/vm.zig`); the tree evaluator in `src/lang.zig` still runs everything else and defines the
  semantics (the bytecode is only used where it behaves the same). Going from the tree evaluator alone (2.4x) to this: in-place
  primitive calls on variables and constants (2.1x), `&&`/`||` short-circuit and native `mod`/`min`/`max`/`abs`/`not`,
  bytecode with fused arithmetic and remembered outer-variable lookups (1.2x), loops (`for`, `for/list`) run by the bytecode with
  the scope of an iteration reused, a function calling itself in tail position reusing its scope, and small global functions
  inlined into their callers (0.67x).
- **Most programs are now faster than CPython**: 0.3x-0.6x for the autograd programs, `matmul`, `kmeans`, `logreg`, `dijkstra`,
  `knapsack`, `bpe` and `mandelbrot`; on par for `life`, `quicksort`, `nbody`, `spectral_norm`, `bigram`.
- **What is left** (`fannkuch` 1.35x, `nqueens` 1.2x, `levenshtein` 1.1x): code that makes many calls to functions that are not
  inlined (a call still builds a scope and a frame, about 25 ns) and tight loops of a few instructions each (about 2 ns an
  instruction).
- **Things that did not help, so are not there**: a size-class allocator in the collector (slower than macOS `malloc`), caching
  the place of a variable in the tree evaluator (no gain), three-operand forms of `+`, running calls between compiled functions
  without leaving `vm.exec` (no gain), a bytecode step for statement sequences, a fused compare-and-branch.
