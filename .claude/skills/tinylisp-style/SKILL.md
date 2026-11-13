---
name: tinylisp-style
description: Good practices for writing tinylisp (this repo's Lisp) code, from its performance behaviour and language features. Use when writing or reviewing .lisp files, stdlib code, macros (defmacro, quasiquote), tests (deftest) or examples such as microgpt, and when something written in tinylisp is slow or behaves oddly.
---

# Writing good tinylisp

Run from the repo root: `./tinylisp -f file.lisp`, `make test`. Measure with `time`, and check a refactor with a
`diff` of the program's output against the output before the change.

## Performance: what is cheap and what is not

**Lists are immutable arrays. `cons` and `cdr`/`rest` copy the whole list**, so a loop that peels a list with `rest`
or grows it with `cons` is quadratic. A `range` written as `(cons i acc)` over 50k items took over a second; the native
`range` is instant. Instead:
- build with the natives: `range`, `zip`, `concat` (variadic, one copy however many lists), `apply`, `map`, `reduce`;
  `(apply concat lists)` (= `flatten`) joins many lists in one copy, `filter` and `flatten` are linear;
  `r/reduce` recurses on `(rest l)` and is quadratic;
- walk with an index and `at` (O(1)), or with `for` / `for/list` / `map`, never by recursing on `(rest l)`;
- update in place with `(vset! lst i x)` when a mutable vector is what you mean (Adam's `m` and `v` buffers);
- a small growable list (`append!` = `concat` per item) is fine for tens of items, not for thousands.

**Walk several lists together with a multi-list `map`**, not a list of pairs: `(map xs ys f)` calls `f` with one item of
each and stops at the shortest. `(for/list ((a b) (zip xs ys)) body)` expands to exactly that. Destructuring a list of
pairs (`(for/list ((a b) pairs) …)`) works but costs two `define`s and two `at`s per item; use it off the hot path.

**Loops are calls.** `for` and `for/list` are `map` with a lambda, so each iteration is a call with its own scope; there is
  no `while`. CPython runs tight index loops 3x-7x faster (bench/README.md); keep inner loops flat, avoid creating a
  quoted list or a closure per iteration, and prefer `reduce`/`sum` over a loop that updates a variable.

**Function calls are the main cost** (in the autograd engine, a small function call plus its allocation was about 0.2 µs). In a hot path:
- do not wrap field access in a function; write the accessors as `defmacro`s (`(defmacro data (v) `(at ~v 0))`). `(data v)` as a function made autograd's `v*` about 5× slower; as a macro that
  expands to `(at v 0)` it costs nothing. Macros run once per node at compile time, so sugar made of macros is free;
- do not call a helper per element when a primitive does it (`+` is variadic, `concat` is variadic);
- hoist work out of loops: build `chain` blocks and other closures once, not per item;
- avoid building strings in a loop (`(+ "layer" i ".attn_wq")` allocates, and `dict-get` is a linear search): look a
  weight up once per call, not once per element.

**Recursion.** Tail calls use no memory; a non-tail call uses heap (a million deep ≈ 260 MB) but never overflows. Write
loops as tail recursion, `defrec` (self tail calls run in a loop), or `for`. Prefer `for`/`map` over recursion that
carries an index, unless you need an early exit (a `for` has no `break`; tail recursion does).

**Memory.** A call's scope is recycled when it ends unless a closure captured it, so closures created in a hot loop
allocate and keep scopes alive. Natives may allocate freely; the collector runs at one safe point.

## Language features and traps

- `0`, `""`, `nil` and `#f` are false; `'()` is true. `eq?` treats `'()` as `nil`.
- **`&&` and `||` do not short-circuit**: every operand is evaluated (they return one of their operands). A guard like
  `(&& (< i n) (at v i))` still evaluates `(at v i)`, and in a hot loop the extra operands cost real time (a three-way
  `&&` in n-queens doubled the run time). Use nested `if` for guards and in hot paths.
- `eq?` on lists is identity; `equal?` compares element-wise at any depth (and lengths). Elements are compared with `eq?`, so see the literal trap below.
- Symbols and strings are the same type, **but a string literal inside quoted data does not `eq?` a string made at run
  time**: `'("a")` holds a literal, `'(a)` a symbol. In a spec, expect `(list 'a "")` rather than `'(a "")`. Compare AST names against symbols (`'(data grad)`) or `(list "data" …)`.
- `lambda` takes **one** body expression. For several, use `defn`, `fn`, `deftest` (all wrap in `begin`) or `begin`. An
  `if` branch is also a single expression: wrap several in `begin`. A lambda body with a second expression silently
  ignores it.
- `(lambda (a & rest) …)`: `rest` is the list of the remaining arguments (empty list if none). Missing arguments are `nil`.
- `define` inside a function body is local; `set!` updates the nearest existing variable (use it for loop accumulators
  inside `for` bodies, which are lambdas).
- Lenient primitives: `(first atom)` is `nil`, `(len atom)` is `0`, `(at l i)` out of range is `nil`. Do not rely on an error.
- No `let`, `when`, `cond`: use `define` in a `defn`/`fn` body, `if`, `begin`.
- Name clash: a `defmacro` named like an existing function rewrites every call of that name, in every file loaded later.

## Macros (`defmacro`, backquote)

```lisp
(defmacro unless (test & body)
  `(if ~test nil (begin ~@body)))
```
`~x` inserts the value of `x`, `~@xs` splices the items of the list `xs`, `'x` quotes. Templates cannot nest.
- **Macro bodies are not macro-expanded.** While a macro runs, no macro applies to the code it runs (expansion does not
  nest). So a macro body and the helper functions it calls may use only functions, special forms and backquote
  (`defmacro` rewrites that for you): no `defn`, `for`, `->`, `val` inside them. Helpers are written with `define` or
  `defn`, and are fine to define with a macro because the *definition* expands normally; it is their *body* that is not.
- Use `begin-of` to wrap a body (`(begin-of body)` is the body itself if there is one expression).
- A macro that must match more than a head symbol (like autograd's `slots`) is a plain `(define macro/name (lambda (ast) …))`
  that returns `ast` unchanged when it does not apply.
- Macros cost nothing at runtime, so prefer one to a function in hot code when all it does is rearrange syntax.

## Idioms that read well

- Thread data with `->`: `(-> probs (at target) vlog vneg)`. Compose blocks with `chain` (each block is any expression
  that evaluates to a one-argument function, evaluated once) and `Sequential` for a computed list of blocks.
- Name sections with a comment line and a dashed line below it (`;; layers` then `;; ----…`).
- Keep an example close to its Python original (names, structure, evaluation order) and prove it by diffing the output;
  floating-point results depend on the order of operations, so keep that order when refactoring.

## Tests

- `deftest name expr…` + `(assert expr message…)` in `spec/specs.lisp`; a failing assert says which test and which expression
  (`deftest` adds that when it expands, via `patch-asserts`), so write plain `(assert …)`.
- Beware assertions that cannot fail: before trusting an `equal?` on a result, check that a wrong value would be caught.
- REPL-visible behaviour goes in `spec/repl.py`. Add a case for every change.
- After changing a native or the evaluator, stress the collector: build with a tiny `limit` in `src/gc.zig` (2048)
  and run both suites and the microgpt example, then put the limit back.
- Do not name a test helper like a macro the specs define (`twice`, …): the macro rewrites it.
