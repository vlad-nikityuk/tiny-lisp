# Tiny Lisp

A tiny Lisp interpreter written for fun, inspired by Peter Norvig's [lispy](http://norvig.com/lispy.html). Written in Zig.

## Language card

| | |
|---|---|
| **Values** | numbers (`42`, `1.5`), booleans `#t` `#f`, `nil`, strings/symbols (`"hi"`, `'hi`), lists `'(1 2 3)`, functions |
| **Falsy** | `#f`, `nil`, `0`, `""` (everything else is true, including `'()`) |
| **Special forms** | `(quote x)` / `'x`, `(if c then else)`, `(define name v)`, `(set! name v)`, `(lambda (args) body)`, `(begin e1 e2 ...)` |
| **Shorthands** | `(defn name (args) body)`, `(defrec name (args) body)`: tail-recursive, runs in constant stack |
| **Arithmetic** | `+ - * /` (variadic), `+` concatenates when any argument is a string |
| **Comparison & logic** | `< > <= >=`, `eq?` (value equality; `'()` equals `nil`), `&&`, `\|\|` (return an operand), `not` |
| **Lists** | `list cons car cdr first rest len at list? empty? map reduce zip concat equal?` |
| **Functions** | closures, `partial`, `trampoline` |
| **Errors** | `(error v)` raises `v`, `(try (lambda () ...) (lambda (e) ...))` catches it |
| **Macros** | any global named `macro/*` rewrites every expression before it runs |
| **Tests** | `(deftest name body)`, `(assert expr)`, `(run-tests)` |
| **I/O** | `print`, `red`, `green`, `pi`; comments start with `;` |

```lisp
(defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(print "10! =" (fact 10))                      ; 10! = 3628800
(map '(1 2 3) (lambda (x) (* x x)))            ; (1 4 9)
```

## Getting started

```bash
make                         # build ./tiny-lisp (needs Zig 0.17)
./tiny-lisp                  # interactive REPL
./tiny-lisp -f file.lisp     # run a file
./tiny-lisp --debug          # start with *DEBUG* set to #t
make test                    # run the test suites
```

Run it from the repository root: it loads `src/stdlib.lisp` on start.

## Handbook

### Values and evaluation

Numbers are 64-bit floats and print without a trailing `.0` when they are whole. Symbols and strings are the same type: `'abc` and `"abc"` are equal under `eq?`. A bare symbol is looked up as a variable; a quoted one or a string literal evaluates to itself.

```lisp
#> (/ 7 2)
3.5
#> (eq? "abc" 'abc)
#t
#> '(a "b" 1.5)
(a "b" 1.5)
```

A list is a function call: the head is evaluated to a function and applied to the evaluated arguments. Calling something undefined is an error:

```lisp
#> (undefined-fn 1)
ToyLisp: Function undefined-fn is not defined
```

### Truthiness

Only `#f`, `nil`, `0` (and NaN) and the empty string are false. The empty list is **true**, but `eq?` treats it as equal to `nil`:

```lisp
#> (if 0 'yes 'no)
no
#> (if '() 'yes 'no)
yes
#> (eq? '() nil)
#t
```

`&&` and `||` return one of their operands, like in JavaScript: `(&& 1 0)` is `0`, `(|| 0 "x")` is `x`.

### Variables and scope

`define` creates a variable in the current scope, `set!` updates the nearest existing one. Scopes are lexical, and lambdas capture their scope:

```lisp
#> (define x 1)
1
#> (set! x 2)
2
#> (define make-adder (lambda (n) (lambda (m) (+ n m))))
#> ((make-adder 10) 5)
15
```

`begin` evaluates expressions in order and returns the last one.

### Functions

```lisp
(define square (lambda (n) (* n n)))
(defn square (n) (* n n))            ; same thing, via the defn macro
((partial + '(1 2)) 3)               ; 6: partial takes the fixed arguments as a list
```

Missing arguments are `nil`; extra arguments are ignored.

### Recursion and tail calls

Recursion is not limited by the native stack: pending work lives on the heap, so even non-tail recursion can go millions of calls deep (memory permitting). Calls in tail position (the branches of `if`, the last expression of `begin`, a function body) don't grow anything at all, so loops written as tail recursion run in constant memory.

`defrec` does the same through an explicit trampoline: it rewrites self-calls into thunks and runs them in a loop.

```lisp
(defrec count (n acc) (if (eq? n 0) acc (count (- n 1) (+ acc 1))))
(count 1000000 0)                    ; 1000000
```

One limit remains: native functions that call back into Lisp (`map`, `reduce`, `try`, `partial`, macros) use the native stack, so callbacks nested more than 8,000 deep raise a catchable `ToyLisp: recursion too deep` error.

### Lists

| Function | Example | Result |
|---|---|---|
| `list` | `(list 1 2)` | `(1 2)` |
| `cons` | `(cons 0 '(1 2))` | `(0 1 2)` |
| `car` / `first` | `(car '(a b))` | `a` (`nil` for an empty list) |
| `cdr` / `rest` | `(cdr '(1))` | `()` |
| `len` | `(len '(1 2 3))` | `3` |
| `at` | `(at '(a b c) 1)` | `b` |
| `list?`, `empty?` | `(empty? '())` | `#t` |
| `map` | `(map '(1 2 3) (lambda (x) (* x x)))` | `(1 4 9)` |
| `reduce` | `(reduce '(1 2 3 4) + 0)` | `10` |
| `zip` | `(zip '(1 2) '(a b))` | `((1 a) (2 b))` |
| `concat` | `(concat '(1 2) '(3 4))` | `(1 2 3 4)` |
| `equal?` | `(equal? '(1 2) '(1 2))` | `#t` (element-wise) |

Lists are immutable arrays: `cons` and `cdr` copy. Note the argument order: the list comes first in `map` and `reduce`.

Church-encoded lists are in the stdlib too: `c/cons`, `c/head`, `c/tail`.

### Errors

`error` raises any value; `try` takes two functions, a body and a handler that receives the raised value:

```lisp
#> (try (lambda () (error 'boom)) (lambda (e) (list 'caught e)))
(caught boom)
```

Interpreter errors (undefined functions, syntax errors, `recursion too deep`) are raised as strings and can be caught the same way.

### Macros

A macro is a function stored in a global whose name starts with `macro/`. Before any expression is evaluated, every macro receives its unevaluated form as a list and returns a replacement (or the form unchanged). Forms are plain lists of strings, so building code is building lists:

```lisp
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (list "not" (first (rest ast))) (first (rest (rest ast))))
      ast)))

(unless #f (print "runs"))
```

Macros run on every node, so each one costs time on every evaluation step. `defn`, `defrec` and `deftest` are themselves macros (see `src/stdlib.lisp`).

### Tests

```lisp
(deftest arithmetic
  (assert (eq? (+ 2 3) 5)))

(run-tests)                          ; prints PASS arithmetic
```

A failing `assert` raises `assertion-failed`, which stops the run with a non-zero exit code.

### Standard library

`src/stdlib_native.zig` provides `print pi list? at map reduce red green partial`; everything else (`first rest not defn defrec empty? iterate zip concat equal? c/cons ... deftest assert run-tests`) is written in Lisp in `src/stdlib.lisp`.

## Implementation

| File | |
|---|---|
| `src/lang.zig` | the evaluator (explicit-stack machine, ≤ 100 lines) |
| `src/runtime.zig` | values, printer, parser, scopes, primitives, trampoline |
| `src/repl.zig` | command line and REPL |
| `src/gc.zig` | memory management |
| `src/stdlib_native.zig`, `src/stdlib.lisp` | standard library |
| `spec/specs.lisp`, `spec/repl.py` | Lisp test suite, REPL tests |

- **Evaluator**: an explicit-stack machine. Pending work (`if` waiting for its condition, `begin` mid-sequence, arguments being evaluated) is a frame on a heap stack, and tail calls replace the current state, which is why recursion depth is bounded by memory, not the native stack. The parser and printer are iterative too.
- **Memory**: reference counts for references stored in the heap, plus per-call allocation regions: when a call returns, everything it allocated that nothing references is freed. Cycles are not collected. Peak memory stays at 2–3 MB on the benchmarks.
- **Performance**: fib 22 takes 0.47 s and a 100k-iteration `defrec` loop 1.09 s on an Apple Silicon Mac, the same as the C version. Running every `macro/*` on every node dominates the time.

## History

1. **CoffeeScript**: the first version.
2. **TypeScript**: a straight port. For a long time it had no proper tail calls, and macro expansion was recursive, so deep programs overflowed the JavaScript stack.
3. **Coding agents**: fixing that became much easier with AI coding agents: a stack-safe evaluator, iterative macro expansion, tests shared across runtimes.
4. **C**: a rewrite with an explicit-stack evaluator and its own memory management, about 5× faster than the TypeScript version on Node.js and using a few MB instead of 100+ MB.
5. **Zig**: a 1:1 port of the C version for readability, at the same speed. It replaced C, whose 100-line limit made the code hard to read.
