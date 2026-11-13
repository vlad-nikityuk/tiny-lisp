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

## Historical results

Historical snapshot (revision and exact Zig version were not recorded; the project uses Zig 0.17).
Apple M2 Max, Python 3.14.5 (no JIT), tinylisp built with `make` (ReleaseSafe), best of 3 whole-process times.
Interpreter start is 0.021 s for Python and 0.003 s for tinylisp, and is included.

| benchmark | python | tinylisp | tinylisp / python |
|---|---|---|---|
| kmeans | 0.295 s | 0.077 s | 0.26x |
| logreg | 0.360 s | 0.117 s | 0.33x |
| dijkstra | 0.344 s | 0.112 s | 0.33x |
| matmul | 0.352 s | 0.124 s | 0.35x |
| knapsack | 0.394 s | 0.138 s | 0.35x |
| mlp_xor (scalar autograd) | 0.301 s | 0.136 s | 0.45x |
| linreg (scalar autograd) | 0.308 s | 0.141 s | 0.46x |
| mandelbrot | 0.324 s | 0.148 s | 0.46x |
| bpe | 0.307 s | 0.175 s | 0.57x |
| nbody | 0.364 s | 0.261 s | 0.72x |
| spectral_norm | 0.266 s | 0.206 s | 0.77x |
| sieve | 0.336 s | 0.283 s | 0.84x |
| quicksort | 0.191 s | 0.171 s | 0.89x |
| levenshtein | 0.197 s | 0.176 s | 0.89x |
| bigram | 0.141 s | 0.141 s | 1.00x |
| life | 0.344 s | 0.352 s | 1.02x |
| nqueens | 0.397 s | 0.421 s | 1.06x |
| fannkuch | 0.408 s | 0.467 s | 1.14x |

Geometric mean: tinylisp takes 0.59x as long as CPython 3.14 (it was 2.4x before the second tier below).

## What the numbers say

- **The evaluator has two tiers.** The first call of a function compiles its body to a stack bytecode with fixed slots for its
  parameters and defines (`src/vm/compiler.zig`, run by `src/vm/exec.zig`); the tree evaluator in `src/lang/` still runs everything else and defines the
  semantics. Bytecode expands the whole body on first call and sees primitive rebinding only on subsequent calls,
  as documented in CLAUDE.md. Fixed slots, fused arithmetic, cached outer lookups, scope reuse, counted loops,
  and small-function inlining contributed to the recorded improvement from 2.4x to 0.59x.
- **Most programs are now faster than CPython**: 0.3x-0.6x for the autograd programs, `matmul`, `kmeans`, `logreg`, `dijkstra`,
  `knapsack`, `bpe` and `mandelbrot`; 0.7x-0.9x for `nbody`, `spectral_norm`, `sieve`, `levenshtein`, `quicksort`; on par for
  `bigram`, `life`, `nqueens`.
- **What is left** is `fannkuch` (1.14x): almost all of its time is bytecode instructions, measured then at about 2 ns each (240M of them), and about
  7M calls that are not inlined (a call builds a scope and a frame, measured then at about 25 ns).
- **Things that did not help, so are not there**: a size-class allocator in the collector (slower than macOS `malloc`), caching
  the place of a variable in the tree evaluator (no gain), three-operand forms of `+`, running calls between compiled functions
  without leaving `vm.exec` (no gain), a bytecode step for statement sequences, a fused compare-and-branch.
