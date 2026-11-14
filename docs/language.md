# Language reference

TinyLisp is a small Lisp: numbers, strings (symbols), lists, closures, macros, and errors. This page describes what the implementation does (`src/` + `stdlib.lisp`).

## Running examples

From the repository root (stdlib loads automatically):

```bash
./tinylisp -f myfile.lisp
echo '(+ 2 3)' | ./tinylisp
```

Verified snippet:

```lisp
(print (+ 2 3))
```

```bash
echo '(print (+ 2 3))' | ./tinylisp
# 5
```

## Syntax

- **Lists** — `(f a b)`; empty list `()` prints as `()`.
- **Quote** — `'x` → `(quote x)`; also `` ` ``, `~`, `~@` via the parser (`parser.zig`).
- **Atoms** — numbers (`42`, `1.5`), booleans `#t` / `#f`, `nil`, bare symbols (variables), `"strings"`.
- **Comments** — `;` to end of line.

Symbols and strings share one runtime type: `(eq? "abc" 'abc)` is `#t`. String **literals** in source (`.lit` in the AST) evaluate to strings; quoted symbols evaluate to themselves.

## Values and truthiness

| Value | Falsy? |
|---|---|
| `#f`, `nil`, `0`, `""` | yes |
| everything else, **including** `'()` | no |

`(eq? '() nil)` is `#t`. Short-circuit: `&&` and `||` return an operand (`(|| 0 "x")` → `"x"`).

## Special forms (core)

Forms in **head** position with dedicated compile rules (`lang/compile.zig`):

| Form | Behaviour |
|---|---|
| `quote` | Unevaluated datum |
| `if` | Branch on truthiness |
| `define` | Bind name (see scope rules below) |
| `set!` | Assign nearest binding; error if none |
| `lambda` | Closure; `(a & rest)` collects extra args into a list |
| `begin` | Sequence; value is last |
| `&&` / `||` | Short-circuit (`Code` nodes) |
| `defmacro` | Top level only; handled in expander, not stdlib |

At top level inside a file or REPL, `define` creates or updates a **global**. Inside a function body, `define` creates a **local slot** for the whole body (hoisted); see below.

## Function-body scope rules

These rules are intentional (stage 2 in `BACKLOG.md`) and enforced by slots + `V.unbound`:

1. Parameters and every `define` anywhere in the body (any branch, argument position, nested `begin`, but **not** inside a nested `lambda`) share one local environment for that function.
2. A local slot exists from entry; until the `define` runs it holds `unbound`. Reading it raises `TinyLisp: x is used before it is defined`.
3. `set!` on an unbound **local** slot assigns it; `set!` with no binding raises `TinyLisp: set!: x is not defined`.
4. `load` and `eval` always run at **top level** in the global scope; they do not see the caller's locals.

```lisp
(defn demo (n)
  (if (< n 0)
    (define sign -1)
    (define sign 1))
  sign)

(print (demo 3))   ; 1
(print (demo -2))  ; -1
```

A branch that never runs still leaves the name defined if another branch defined it (same slot).

Nested lambdas get their own bodies. Local helpers in one body may call each other (letrec*-like): all slots exist before execution starts.

## Calls and functions

- **Closures** — `(lambda (args) body…)`; missing args are `nil`, extra args ignored (except `& rest`).
- **Tail calls** — Last expression in `begin`, `if` branches, lambda body: no extra frame when the callee is a function (self tail calls recycle the scope when no closure captured it).
- **`defn` / `fn`** — Macros in `stdlib.lisp`: `defn` → `define` + multi-expression `lambda`; `fn` → anonymous multi-expression `lambda`.

## Macros and `defmacro`

`(defmacro name (params & body) …)` at top level (including inside a top-level `begin`) expands and installs a function in `scope.macros` **before** the rest of the top-level form is expanded.

- Each **top-level form** is fully expanded before compile/run: macro calls in lambda bodies are expanded too.
- Macro argument lists support `& rest` like `lambda`.
- Redefining a macro affects only **later** forms; earlier expansions are fixed.
- Macro expansion uses a nested machine; user evaluation does not nest except for macros and FFI callbacks.

```lisp
(defmacro unless (test & body)
  `(if ~test nil (begin ~@body)))

(unless #f (print "runs"))
```

## Quasiquote

Bootstrapping in `stdlib.lisp`: `quasiquote` macro builds templates. `~expr` inserts; `~@list` splices. Nested quasiquote is rejected at expand/run time.

## Stdlib macros and forms

Defined in `src/lib/stdlib.lisp` (after `quasiquote`):

| Form | Expands to / meaning |
|---|---|
| `for` | `(each list (lambda (x) …))` — side-effect loop, returns `nil` |
| `for/list` | `(map list …)` — collect results |
| `->` | Thread-first: `(-> x f (g a))` → `(g (f x) a)` |
| `chain` | Compose one-arg functions (Keras-style blocks) |
| `defrec` | Thunk self-calls + `trampoline` |
| `deftest` / `assert` | Test harness (`run-tests` at end of suite) |

List primitives: many in `runtime/primitives.zig` and `lib/natives.zig` (`map`, `reduce`, `range`, `zip`, `apply`, …). `vset!` mutates a list slot in place for records/vectors.

## Operators

Variadic `+ - * /` (`+` concatenates strings with a string argument). Comparisons `< > <= >=`, `eq?` (identity), `not`. Global numeric primitives may fuse into VM instructions when still bound to the original natives.

## Errors

`(error v)` raises any value. `(try thunk handler)` — both arguments are functions; handler receives the error value.

Interpreter failures use string messages (often `TinyLisp: …`) and are catchable the same way:

```lisp
(try (lambda () (/ 1 0))
     (lambda (e) (list 'err e)))
```

## Files

`(read-file path)`, `(write-file path text)`, `(split text sep)`, `(load path)` — `load` evaluates each top-level form in the global scope.

## Further reading

- Bytecode and performance: [vm.md](vm.md)
- `call/cc`: [continuations.md](continuations.md)
- C libraries: [ffi.md](ffi.md)