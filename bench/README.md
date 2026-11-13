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
| mlp_xor (scalar autograd) | 0.303 s | 0.334 s | 1.10x |
| linreg (scalar autograd) | 0.309 s | 0.352 s | 1.14x |
| logreg | 0.351 s | 0.400 s | 1.14x |
| matmul | 0.368 s | 0.433 s | 1.18x |
| kmeans | 0.297 s | 0.374 s | 1.26x |
| sieve | 0.384 s | 0.624 s | 1.63x |
| bpe | 0.307 s | 0.512 s | 1.67x |
| spectral_norm | 0.278 s | 0.519 s | 1.87x |
| dijkstra | 0.347 s | 0.651 s | 1.88x |
| bigram | 0.142 s | 0.303 s | 2.13x |
| knapsack | 0.402 s | 1.055 s | 2.62x |
| mandelbrot | 0.327 s | 0.975 s | 2.98x |
| quicksort | 0.194 s | 0.656 s | 3.37x |
| nbody | 0.359 s | 1.265 s | 3.53x |
| fannkuch | 0.409 s | 1.915 s | 4.68x |
| levenshtein | 0.200 s | 1.185 s | 5.93x |
| nqueens | 0.399 s | 2.852 s | 7.16x |
| life | 0.337 s | 2.516 s | 7.46x |

Geometric mean: tinylisp takes 2.4x as long as CPython 3.14.

## What the numbers say

- **Allocation-heavy, call-heavy code is on par** (1.1x-1.3x): the autograd programs build thousands of small lists
  and call small functions, which is what microgpt does, and what the evaluator and the collector are tuned for.
- **Tight loops over indices are where CPython wins** (3x-7x): `nqueens`, `life`, `levenshtein`, `fannkuch`, `nbody`.
  Python's `for` and `while` are bytecode; here `for` is a `map` with a lambda, so every iteration is a call with a
  scope, and there is no `while`.
- **`&&` and `||` evaluate all their operands.** `nqueens` with the three-way `&&` replaced by nested `if`s takes
  1.5 s instead of 2.85 s (checked). Python's `and` stops at the first false operand. Making `&&`/`||` short-circuit
  (a macro) is the cheapest likely win for `nqueens`, `life`, `dijkstra` and `levenshtein`.
- **Arithmetic on numbers is not the problem**: the float programs (`logreg`, `matmul`, `kmeans`) are within 1.3x.
