# The Python side of the benchmarks

Nothing here is vendored: each file is a short rewrite written for this repo, so that its tinylisp twin in `bench/`
can follow it line for line (plain loops and lists, no C-accelerated tricks, integer checksums as output). Several
follow a published algorithm, and a few reuse its constants or its structure; this is where they come from.

| file | origin | what is borrowed |
|---|---|---|
| `value.py` | [micrograd](https://github.com/karpathy/micrograd) `engine.py`, and the `Value` class of [microgpt.py](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95) | the class, its operators and the backward pass; `__pow__` uses `exp`/`log` like `examples/autograd.lisp` |
| `mlp_xor.py`, `linreg.py` | the micrograd demo (an MLP trained by SGD on scalar `Value`s) | the idea; the network, data and loop are new |
| `bigram.py` | the bigram model of [makemore](https://github.com/karpathy/makemore) | the idea: count character pairs, score with smoothing, sample |
| `bpe.py` | [minbpe](https://github.com/karpathy/minbpe) | the algorithm (merge the most frequent pair); a flat count table replaces its dict |
| `nbody.py` | [n-body, Computer Language Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/performance/nbody.html); also [pyperformance `bm_nbody`](https://github.com/python/pyperformance/tree/main/pyperformance/data-files/benchmarks/bm_nbody) | the five bodies' initial conditions and the integrator |
| `spectral_norm.py` | [spectral-norm, Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/performance/spectralnorm.html); [pyperformance `bm_spectral_norm`](https://github.com/python/pyperformance/tree/main/pyperformance/data-files/benchmarks/bm_spectral_norm) | the matrix formula and the power method |
| `fannkuch.py` | [fannkuch-redux, Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/performance/fannkuchredux.html); [pyperformance `bm_fannkuch`](https://github.com/python/pyperformance/tree/main/pyperformance/data-files/benchmarks/bm_fannkuch) | the permutation walk and the flip count; slicing replaced by explicit loops |
| `nqueens.py` | [pyperformance `bm_nqueens`](https://github.com/python/pyperformance/tree/main/pyperformance/data-files/benchmarks/bm_nqueens) is the same problem | only the problem: this is the textbook backtracking with column and diagonal flags |
| `mandelbrot.py` | [mandelbrot, Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/performance/mandelbrot.html) | only the problem: escape-time counting on a grid |
| `sieve.py` | the sieve of Eratosthenes | textbook |
| `life.py` | [Conway's Game of Life](https://en.wikipedia.org/wiki/Conway%27s_Game_of_Life) | textbook, on a torus |
| `levenshtein.py` | [Wagner-Fischer](https://en.wikipedia.org/wiki/Wagner%E2%80%93Fischer_algorithm), two rows | textbook |
| `knapsack.py` | [0/1 knapsack](https://en.wikipedia.org/wiki/Knapsack_problem#0-1_knapsack_problem), one-dimensional table | textbook |
| `dijkstra.py` | [Dijkstra](https://en.wikipedia.org/wiki/Dijkstra%27s_algorithm), the O(V^2) array version | textbook |
| `quicksort.py` | [Lomuto partition](https://en.wikipedia.org/wiki/Quicksort#Lomuto_partition_scheme) | textbook |
| `logreg.py`, `kmeans.py`, `matmul.py` | logistic regression by gradient descent, Lloyd's k-means, the triple-loop matrix product | textbook |

The Benchmarks Game programs are published under the revised BSD licence; the files here are rewrites that keep only
the algorithm and, for `nbody.py`, the published initial conditions.

To compare against the originals instead of these rewrites, fetch them (they are not needed by `bench/run.py`):

```bash
curl -O https://raw.githubusercontent.com/python/pyperformance/main/pyperformance/data-files/benchmarks/bm_nbody/run_benchmark.py
```
