<p align="center">
  <img src="docs/logo.png" alt="TinyLisp" width="360">
</p>

# TinyLisp

A tiny Lisp interpreter in Zig, written for fun and inspired by Peter Norvig's [lispy](http://norvig.com/lispy.html).

```lisp
(defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
(print "10! =" (fact 10))                      ; 10! = 3628800
(map '(1 2 3) (lambda (x) (* x x)))            ; (1 4 9)
```

- It is a Lisp: numbers, strings, lists, closures, `define`, `lambda`, `if`, `quote`, errors caught with `try`.
- It is small: the parser, compiler and evaluator are about 400 lines (`src/lang/`) and the whole interpreter, with its bytecode tier and collector, is about 2,600 lines of Zig, with no dependencies beyond libc.
- It is fast: a small GPT trained with scalar autograd runs as fast as under CPython, in the same memory (see Performance).
- It has macros: `defmacro` defines one, and every form is expanded before it runs.
- It has tail-call optimization and is stack safe: recursion is limited only by memory.
- It has a small mark-sweep GC that runs at a few safe points of the evaluator. Reference cycles are collected.

## Stack safety

Pending work lives in heap frames, not on the native stack, so recursion is limited by memory and nothing else, even when it goes through `map`, `reduce`, `partial` or `try`. A non-tail recursion a million calls deep works (it takes about 260 MB). Tail calls use no memory.

```lisp
(defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
(deep 1000000)                                 ; 1000000
```

## Performance

Memory is managed by a stop-the-world mark-sweep collector that runs once about as much as is live (at least 2 MB) has been allocated, so a program that churns through garbage stays small.

`examples/microgpt.lisp` trains a one-layer GPT with a scalar autograd engine (10 steps, then 5 samples; about 4,200 parameters) and prints the same losses and names as Karpathy's [microgpt.py](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95) run with the same random numbers and names. The Lisp port builds the same graph as the gist's `Value` class, and macros keep its code close to the gist's: `(val a * b + c)` is infix arithmetic on values, `for/list` and `for` are comprehensions and loops, and the model is built from blocks, `(chain rmsnorm (Residual (chain rmsnorm (Attention keys values) (Linear attn-wo))) …)`.

| microgpt, 10 steps + 5 samples | Python 3.14 | tinylisp |
|---|---|---|
| time | 0.93–0.97 s | 0.81 s |
| peak memory | 55 MB | 55 MB |

Apple Silicon, best of 3 runs.

[`bench/`](bench/README.md) has 18 more programs like this one, each in Python and in tinylisp, with the same output and a runner that compares them: in the recorded run tinylisp takes 0.26x-1.14x as long as CPython 3.14 (0.59x as a geometric mean).

## Macros

A macro is a function that makes code. Each top-level form is read, expanded and then run, one after the other: before the form runs, every call of a macro in it (in the bodies of its lambdas too) is replaced by what the macro returns for the parts of the call. `(defmacro name (params) body...)` defines one: it is made as soon as its form is expanded, so the forms after it see it (and a macro body may use the macros and functions defined before it), and `&` collects the rest of the parts, like in a `lambda`. A backquote template is the new form, with `~x` inserting the value of `x` and `~@xs` splicing in the items of the list `xs`.

```lisp
(defmacro unless (test & body)
  `(if ~test nil (begin ~@body)))

(unless #f (print "runs"))
```

Redefining a macro changes the forms that come after it; code that was expanded already keeps its expansion. `defmacro` is only allowed at top level (directly in a file, or inside a top-level `begin`); anywhere else is an error. A template cannot contain another template (an error), though one may sit inside a `~` of another.

`defn`, `fn`, `defrec`, `for`, `for/list`, `->`, `chain` and `deftest` are macros defined this way in `src/lib/stdlib.lisp`.

## Get started

You need [Zig 0.17](https://ziglang.org/download/).

```bash
make                         # build ./tinylisp
./tinylisp                  # REPL
./tinylisp -f file.lisp     # run a file
make test                    # run the tests
make bench                   # compare with CPython on the programs in bench/
```

Run it from the repository root: it loads `src/lib/stdlib.lisp` on start.

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
| `(lambda (a & rest) body)` | `rest` is the list of the arguments after `a` |
| `(begin e1 e2 ...)` | evaluate in order, return the last |
| `(defn name (args) body...)` | shorthand for `define` + `lambda`; several body expressions run as a `begin` |
| `(defrec name (args) body)` | like `defn`, with self tail calls run in a loop |
| `(fn (args) body...)` | a `lambda` with several body expressions |
| `(-> x f (g a))` | thread a value through steps: `(g (f x) a)`, like a stream pipeline |
| `(chain f g h)` | the function `x ↦ (h (g (f x)))`; each step is an expression evaluated once, like a Keras `Sequential` |
| `(for (x lst) body...)` | run the body for each item (a loop, returns `nil`) |
| `(for/list (x lst) body...)` | the list of the body's values, like a Python comprehension |

In both loops the variable can be a pattern, `((a b) (zip xs ys))`, which walks the lists side by side.

Operators: `+ - * /` (variadic; `+` concatenates when an argument is a string), `< > <= >=`, `eq?`, `&&`, `||`, `not`.

### Lists

Lists are immutable arrays: `cons` and `cdr` copy. The list comes first in `map` and `reduce`.

| | | |
|---|---|---|
| `(list 1 2)` | `(1 2)` | `(cons 0 '(1 2))` → `(0 1 2)` |
| `(car '(a b))` / `first` | `a` | `nil` for an empty list |
| `(cdr '(1))` / `rest` | `()` | |
| `(len '(1 2 3))` | `3` | `(at '(a b c) 1)` → `b` |
| `(map '(1 2 3) (lambda (x) (* x x)))` | `(1 4 9)` | `(map xs ys f)` calls `f` with one item of each |
| `(range 3)` | `(0 1 2)` | `(apply + '(1 2 3))` → `6` |
| `(filter lst keep?)` | the items `keep?` accepts | `(flatten '((1) (2 3)))` → `(1 2 3)` |
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
(deftest "arithmetic: addition" (assert (eq? (+ 2 3) 5)))
(run-tests)                                    ; ✔ arithmetic: addition
```

A failing `assert` stops the run with a non-zero exit code and says which test and which expression failed: `assertion failed in arithmetic: addition: (eq? (+ 2 3) 6)`.

### Recursion

Tail calls (the branches of `if`, the last expression of `begin`, a function body) use no memory, so loops written as tail recursion run forever. There is no recursion limit other than memory: a `map` callback that recurses, or a `try` nested a hundred thousand deep, works like any other call.

### Standard library

`src/runtime/primitives.zig` defines the primitives `+ - * / mod < > <= >= eq? car cdr len cons list at not min max abs error exp log sqrt cos floor` and `(vset! list i v)`, which stores into a list in place (lists are otherwise immutable; this makes them usable as mutable records and vectors); `try` and `trampoline` are natives of `src/runtime/machine.zig`. `src/lib/natives.zig` provides `print list? map each reduce partial concat range zip apply read-file write-file split load eval`. Everything else (`pi rand color red green first rest second third quasiquote defn defrec fn -> chain for for/list empty? iterate flatten filter equal? deftest assert run-tests`) is written in Lisp in `src/lib/stdlib.lisp`.

### Files and strings

`(read-file path)` returns a file's text, `(write-file path text)` replaces it, `(split text sep)` cuts a string into a list (an empty `sep` gives single characters), and `(load path)` evaluates a file's expressions in the caller's scope. Each call opens, uses and closes the file itself, so there are no handles to leak; failures raise errors that `try` catches.

## Examples

Run from the repository root.

- `examples/microgpt.lisp` (with `examples/autograd.lisp` and the layers in `examples/nn.lisp`): a port of Karpathy's [microgpt.py](https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95) (scalar autograd, one-layer GPT, Adam, sampling).

## Under the hood

| File | |
|---|---|
| `src/repl.zig` | the entry point: command line, REPL, setting up the root scope |
| `src/lang/parser.zig` | parser: text to AST |
| `src/lang/expand.zig`, `src/lang/compile.zig`, `src/lang/eval.zig` | the tree tier, the reference semantics: macro expansion of a top-level form (and `defmacro`), the expanded AST to nodes, and the evaluator that runs them |
| `src/runtime/` | what all of the above share: `value.zig` (values, printer), `node.zig` (compiled code as data), `scope.zig` (scopes, globals, recycling), `machine.zig` (the stacks, natives that call back into Lisp), `primitives.zig` (`+ - car cons ...`), `gc.zig` (mark-sweep) |
| `src/vm/` | the second tier, the fast path: `bytecode.zig` (the format), `scan.zig` and `compiler.zig` (function body to bytecode), `exec.zig` (the executor) |
| `src/lib/natives.zig`, `src/lib/source.zig`, `src/lib/stdlib.lisp` | the standard library: native part, file loading, Lisp part |
| `spec/specs.lisp`, `spec/repl.py` | Lisp test suite, REPL tests |

The evaluator keeps `if` waiting for its condition, `begin` mid-sequence, arguments being evaluated and a `map` or `try` waiting for its callback as frames on a heap stack, and tail calls replace the current state. The parser, printer and freeing are iterative too. Macros are expanded before a top-level form runs (the expander runs macro bodies on a nested machine; running a form never nests one). Each node of the expanded code is compiled once, the first time it is evaluated: names are resolved to interned symbols with cached global slots, and later visits only dispatch on the node. Scopes of finished calls are recycled unless a closure captured them, and values are 8 bytes (NaN-boxed). A function's body is compiled to a stack bytecode on its first call when the second tier can handle it; the tree evaluator runs everything else and defines the semantics.

## History

1. **CoffeeScript** (2015): the project started here, with the first version.
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
