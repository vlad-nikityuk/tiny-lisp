# Tiny Lisp

A tiny Lisp interpreter in Zig, written for fun and inspired by Peter Norvig's [lispy](http://norvig.com/lispy.html).

```lisp
(defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(print "10! =" (fact 10))                      ; 10! = 3628800
(map '(1 2 3) (lambda (x) (* x x)))            ; (1 4 9)
```

## 1. Tiny Lisp is SMALL.

The evaluator is one file of under 100 lines (`src/lang.zig`), the whole interpreter about 740 lines of Zig. Values, parser, scopes, macros, tail calls, closures, errors, a test framework and a standard library, with no dependencies beyond libc.

## 2. Tiny Lisp is STACK-SAFE.

Pending work lives in heap frames, not on the native stack, so recursion is limited by memory and nothing else, even when it goes through `map`, `reduce`, `partial` or `try`. A non-tail recursion a million calls deep just works (it takes about 260 MB). Tail calls use no memory at all.

```lisp
(defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
(deep 1000000)                                 ; 1000000
```

## 3. Tiny Lisp is FAST, and light.

Memory is managed with reference counts plus per-call allocation regions: no tracing GC, and a program that churns through garbage stays flat at 2–3 MB.

| | TypeScript on Node.js | Tiny Lisp (Zig) |
|---|---|---|
| fib 22 | 2.29 s | **0.44 s** (5×) |
| 100k-step `defrec` loop | 5.01 s | **1.02 s** (5×) |
| allocation-heavy churn | 6.59 s | **1.34 s** (5×) |
| peak memory | 51–146 MB | **2–3 MB** |

Apple Silicon, median of 5 runs, measured on the original TypeScript version (see `git log`).

## 4. Tiny Lisp has MACROS.

A macro is a function named `macro/…`. Before any expression runs, every macro gets to rewrite it. `defn`, `defrec` and `deftest` are macros written in Lisp (`src/stdlib.lisp`).

```lisp
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (list "not" (first (rest ast))) (first (rest (rest ast))))
      ast)))

(unless #f (print "runs"))
```

## 5. Get started.

You need [Zig 0.17](https://ziglang.org/download/).

```bash
make                         # build ./tiny-lisp
./tiny-lisp                  # REPL
./tiny-lisp -f file.lisp     # run a file
make test                    # run the tests
```

Run it from the repository root: it loads `src/stdlib.lisp` on start.

## 6. Guide

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

`src/stdlib_native.zig` provides `print list? at map reduce partial`. Everything else (`pi color red green first rest not defn defrec empty? iterate zip concat equal? c/cons ... deftest assert run-tests`) is written in Lisp in `src/stdlib.lisp`.

## 7. Under the hood

| File | |
|---|---|
| `src/lang.zig` | the evaluator: an explicit-stack machine |
| `src/runtime.zig` | values, printer, parser, scopes, primitives, trampoline |
| `src/gc.zig` | memory management |
| `src/repl.zig` | command line and REPL |
| `src/stdlib_native.zig`, `src/stdlib.lisp` | standard library |
| `spec/specs.lisp`, `spec/repl.py` | Lisp test suite, REPL tests |

The evaluator keeps `if` waiting for its condition, `begin` mid-sequence, arguments being evaluated and a `map` or `try` waiting for its callback as frames on a heap stack, and tail calls replace the current state. The parser, printer and freeing are iterative too. Running every `macro/*` on every node dominates the run time.

## 8. History

1. **CoffeeScript**: the first version.
2. **TypeScript**: a straight port. For a long time it had no proper tail calls, and macro expansion was recursive, so deep programs overflowed the JavaScript stack.
3. **Coding agents**: fixing that became much easier with AI coding agents: a stack-safe evaluator, iterative macro expansion, tests shared across runtimes.
4. **C**: a rewrite with an explicit-stack evaluator and its own memory management, about 5× faster than the TypeScript version on Node.js.
5. **Zig**: a 1:1 port of the C version for readability, at the same speed. It replaced C, whose 100-line limit made the code hard to read.
