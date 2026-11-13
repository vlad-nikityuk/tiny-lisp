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
| kmeans | 0.299 s | 0.093 s | 0.31x |
| logreg | 0.358 s | 0.134 s | 0.37x |
| matmul | 0.359 s | 0.135 s | 0.38x |
| dijkstra | 0.344 s | 0.134 s | 0.39x |
| mlp_xor (scalar autograd) | 0.302 s | 0.153 s | 0.51x |
| knapsack | 0.405 s | 0.205 s | 0.51x |
| linreg (scalar autograd) | 0.309 s | 0.160 s | 0.52x |
| mandelbrot | 0.326 s | 0.183 s | 0.56x |
| bpe | 0.302 s | 0.245 s | 0.81x |
| sieve | 0.375 s | 0.379 s | 1.01x |
| nbody | 0.360 s | 0.372 s | 1.03x |
| bigram | 0.143 s | 0.150 s | 1.05x |
| spectral_norm | 0.270 s | 0.330 s | 1.22x |
| nqueens | 0.397 s | 0.497 s | 1.25x |
| life | 0.339 s | 0.439 s | 1.29x |
| levenshtein | 0.199 s | 0.288 s | 1.45x |
| fannkuch | 0.410 s | 0.603 s | 1.47x |
| quicksort | 0.195 s | 0.292 s | 1.50x |

Geometric mean: tinylisp takes 0.76x as long as CPython 3.14 (it was 2.4x before the second tier below).

## What the numbers say

- **The evaluator has two tiers.** The first call of a function compiles its body to a stack bytecode with fixed slots for its
  parameters and defines (`src/vm.zig`); the tree evaluator in `src/lang.zig` still runs everything else and defines the
  semantics (the bytecode is only used where it behaves the same). Going from the tree evaluator alone (2.4x) to this: in-place
  primitive calls on variables and constants (2.1x), `&&`/`||` short-circuit and native `mod`/`min`/`max`/`abs`/`not`,
  bytecode with fused arithmetic, outer-variable lookups remembered after the first (about 1.2x), then loops run by the bytecode
  with the scope of an iteration reused (0.76x).
- **Programs that call small functions and do arithmetic are now faster than CPython** (0.3x-0.6x): the autograd programs,
  `matmul`, `kmeans`, `logreg`, `dijkstra`, `knapsack`, `mandelbrot` (a tail-recursive function that calls itself reuses its scope).
- **What is left is loop-heavy code** (1.0x-1.5x: `quicksort`, `fannkuch`, `levenshtein`, `life`, `nqueens`, `spectral_norm`):
  a loop body that calls out to something that is not compiled, or that creates a closure, goes through the machine and
  loses the scope reuse; every call still builds a scope and a frame.
- **Things that did not help, so are not there**: a size-class allocator in the collector (slower than macOS `malloc`), caching
  the place of a variable in the tree evaluator (no gain), three-operand forms of `+`, running calls between compiled functions
  without leaving `vm.exec` (no gain), a bytecode step for statement sequences.
