# TinyLisp

A tiny Lisp interpreter in Zig, written for fun and inspired by Peter Norvig's [lispy](http://norvig.com/lispy.html).

```lisp
(defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(print "10! =" (fact 10))                      ; 10! = 3628800
(map '(1 2 3) (lambda (x) (* x x)))            ; (1 4 9)
```

- It is a Lisp: numbers, strings, lists, closures, `define`, `lambda`, `if`, `quote`, errors caught with `try`.
- It is small: the compiler, evaluator and parser are one file of 200 lines (`src/lang.zig`) and the whole interpreter is about 1,100 lines of Zig, with no dependencies beyond libc.
- It is fast: a small GPT trained with scalar autograd runs as fast as under CPython, in the same memory (see Performance).
- It has macros: any function named `macro/…` rewrites every expression before it runs.
- It has tail-call optimization and is stack safe: recursion is limited only by memory.
- It has a small mark-sweep GC that runs at one safe point of the evaluator loop. Reference cycles are collected.

## Stack safety

Pending work lives in heap frames, not on the native stack, so recursion is limited by memory and nothing else, even when it goes through `map`, `reduce`, `partial` or `try`. A non-tail recursion a million calls deep works (it takes about 260 MB). Tail calls use no memory.

```lisp
(defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
(deep 1000000)                                 ; 1000000
```

## Performance

Memory is managed by a stop-the-world mark-sweep collector that runs once about as much as is live (at least 4 MB) has been allocated, so a program that churns through garbage stays small.

`examples/microgpt.lisp` trains a one-layer GPT with a scalar autograd engine (10 steps, then 5 samples; about 4,200 parameters) and prints the same losses and names as Karpathy's [microgpt.py](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95) run with the same random numbers and names. The Lisp port builds the same graph as the gist's `Value` class.

| microgpt, 10 steps + 5 samples | Python 3.14 | tinylisp |
|---|---|---|
| time | 0.93–0.97 s | 0.79 s |
| peak memory | 55 MB | 55 MB |

Apple Silicon, best of 3 runs.

## Macros

A macro is a function named `macro/…`. Before any expression runs, every macro gets to rewrite it. `defn`, `defrec` and `deftest` are macros written in Lisp (`src/stdlib.lisp`).

```lisp
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (list "not" (first (rest ast))) (first (rest (rest ast))))
      ast)))

(unless #f (print "runs"))
```

## Get started

You need [Zig 0.17](https://ziglang.org/download/).

```bash
make                         # build ./tinylisp
./tinylisp                  # REPL
./tinylisp -f file.lisp     # run a file
make test                    # run the tests
```

Run it from the repository root: it loads `src/stdlib.lisp` on start.

## Guide

### Values

Numbers (`42`, `1.5`), booleans (`#t`, `#f`), `nil`, lists (`'(1 2 3)`), functions, and strings. Symbols and strings are the same type, so `(eq? "abc" 'abc)` is `#t`. A bare symbol is a variable; a quoted one or a string literal evaluates to itself. Comments start with `;`.

### Truthiness

`#f`, `nil`, `0` and `""` are false. Everything else is true, **including the empty list** (but `(eq? '() nil)` is `#t`). `&&` and `||` return one of their operands: `(|| 0 "x")` is `"x"`.

### Forms

| | |
|---|---|
| `(quote x)` or `'x` | the unevaluated `x` |
| `(if c a b)` | `a` if `c` is true, else `b` |
| `(define name v)` | create a variable in the current scope |
| `(set! name v)` | update the nearest existing variable |
| `(lambda (args) body)` | a closure; missing arguments are `nil`, extra ones are ignored |
| `(begin e1 e2 ...)` | evaluate in order, return the last |
| `(defn name (args) body)` | shorthand for `define` + `lambda` |
| `(defrec name (args) body)` | like `defn`, with self tail calls run in a loop |

Operators: `+ - * /` (variadic; `+` concatenates when an argument is a string), `< > <= >=`, `eq?`, `&&`, `||`, `not`.

### Lists

Lists are immutable arrays: `cons` and `cdr` copy. The list comes first in `map` and `reduce`.

| | | |
|---|---|---|
| `(list 1 2)` | `(1 2)` | `(cons 0 '(1 2))` → `(0 1 2)` |
| `(car '(a b))` / `first` | `a` | `nil` for an empty list |
| `(cdr '(1))` / `rest` | `()` | |
| `(len '(1 2 3))` | `3` | `(at '(a b c) 1)` → `b` |
| `(map '(1 2 3) (lambda (x) (* x x)))` | `(1 4 9)` | |
| `(reduce '(1 2 3 4) + 0)` | `10` | |
| `(zip '(1 2) '(a b))` | `((1 a) (2 b))` | `(concat '(1 2) '(3 4))` → `(1 2 3 4)` |
| `list?`, `empty?`, `equal?` | | `equal?` compares element-wise |

Also `partial` (`((partial + '(1 2)) 3)` is `6`) and Church-encoded lists `c/cons`, `c/head`, `c/tail`.

### Errors

`(error v)` raises any value; `(try body-fn handler-fn)` runs the body and, if it raised, calls the handler with the value:

```lisp
(try (lambda () (error 'boom)) (lambda (e) (list 'caught e)))   ; (caught boom)
```

Interpreter errors (undefined functions, syntax errors) are raised as strings and caught the same way.

### Tests

```lisp
(deftest arithmetic (assert (eq? (+ 2 3) 5)))
(run-tests)                                    ; PASS arithmetic
```

A failing `assert` raises `assertion-failed` and stops the run with a non-zero exit code.

### Recursion

Tail calls (the branches of `if`, the last expression of `begin`, a function body) use no memory, so loops written as tail recursion run forever. There is no recursion limit other than memory: a `map` callback that recurses, or a `try` nested a hundred thousand deep, works like any other call.

### Standard library

`src/stdlib_native.zig` provides `print list? at map reduce partial concat read-file write-file split load`; `src/runtime.zig` adds the math primitives `exp log sqrt cos floor` and `(vset! list i v)`, which stores into a list in place (lists are otherwise immutable; this makes them usable as mutable records and vectors). Everything else (`pi rand color red green first rest not defn defrec empty? iterate zip concat equal? c/cons ... deftest assert run-tests`) is written in Lisp in `src/stdlib.lisp`.

### Files and strings

`(read-file path)` returns a file's text, `(write-file path text)` replaces it, `(split text sep)` cuts a string into a list (an empty `sep` gives single characters), and `(load path)` evaluates a file's expressions in the caller's scope. Each call opens, uses and closes the file itself, so there are no handles to leak; failures raise errors that `try` catches.

## Examples

Run from the repository root.

- `examples/microgpt.lisp` (with `examples/autograd.lisp`): a port of Karpathy's [microgpt.py](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95) (scalar autograd, one-layer GPT, Adam, sampling).

## Under the hood

| File | |
|---|---|
| `src/lang.zig` | parser, compiler, evaluator |
| `src/runtime.zig` | values, scopes, primitives, trampoline |
| `src/gc.zig` | memory management (mark-sweep) |
| `src/repl.zig` | REPL |
| `src/stdlib_native.zig`, `src/stdlib.lisp` | standard library (native part and Lisp part) |
| `spec/specs.lisp`, `spec/repl.py` | Lisp test suite, REPL tests |

The evaluator keeps `if` waiting for its condition, `begin` mid-sequence, arguments being evaluated and a `map` or `try` waiting for its callback as frames on a heap stack, and tail calls replace the current state. The parser, printer and freeing are iterative too. Each node is compiled once, the first time it is evaluated: macros run then (defining a macro makes nodes compile again), names are resolved to interned symbols with cached global slots, and later visits only dispatch on the node. Numbers, booleans and nil are not passed to macros. Scopes of finished calls are recycled unless a closure captured them, and values are 8 bytes (NaN-boxed).

## History

1. **CoffeeScript**: the first version.
2. **TypeScript**: a straight port. For a long time it had no proper tail calls, and macro expansion was recursive, so deep programs overflowed the JavaScript stack.
3. **Coding agents**: fixing that became much easier with AI coding agents: a stack-safe evaluator, iterative macro expansion, tests shared across runtimes.
4. **Zig**: a rewrite with an explicit-stack evaluator and its own memory management, about 5× faster than the TypeScript version on Node.js. The first attempt was in C, but it was less readable than Zig, so the Zig port replaced it.

The first Zig version against the TypeScript one:

| | TypeScript/Node.js | Zig |
|---|---|---|
| fib 22 | 2.29 s | 0.44 s (5×) |
| 100k-step `defrec` loop | 5.01 s | 1.02 s (5×) |
| allocation-heavy churn | 6.59 s | 1.34 s (5×) |
| peak memory | 51–146 MB | 2–3 MB |

Apple Silicon, median of 5 runs.
