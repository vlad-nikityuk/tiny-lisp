# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make                       # build ./tinylisp (Zig 0.17, ReleaseSafe: bounds/overflow checks, links libc)
make test                  # spec/repl.py + spec/specs.lisp
make fast                  # ReleaseFast build without the checks (~4% faster): ./tinylisp-fast
./tinylisp [-f file.lisp] [--debug]
zig fmt --check src/       # lang.zig opts out; all other Zig sources stay formatted
```

## Architecture

`src/lang.zig` is the compiler, the explicit-stack evaluator (`eval`/`exec`, which runs compiled nodes) and the parser (`parse`). Keep it at **200 lines or fewer**, including comments and blank lines: it starts with `// zig fmt: off`, groups related statements, and keeps short section comments. Keep names meaningful and the total source small; move support code rather than hiding evaluator control flow.

The compiler turns the AST into typed nodes (`runtime.Node`/`Code`: constant, variable, if, begin, define/set!, lambda, call) lazily, the first time a node is evaluated: macro/* expansion happens there (once per node; `runtime.epoch` is bumped when a macro/* changes and nodes compile again; `in_macro` turns expansion off inside macros), symbols are interned (`Sym`; scope keys compare by address; a name no scope has ever bound (`Sym.local`) is looked up in the global table directly, with the slot cached in the node). Nodes, their arrays and symbols are permanent (`gc.perm`); the AST they came from (and macro expansions) is pinned for good with `runtime.pin`, so frames and closures (`Lam.proto`) point at nodes freely.

`src/runtime.zig` holds values (and the printer, `V.format`), the machine state (`K`, `Go`, `ks`, `vs`), constructors, scopes and macro registration, primitives, the natives that call back into Lisp (as machine frames: `start`/`step`/`finish`/`callback`/`tail`, `try`, `recover`, the trampoline), and root-scope initialization. It raises errors through `lang.errv`; other modules import `runtime.zig` directly; `lang.zig` only exposes `eval`, `parse`, `out` and `errv`. Primitives (`+ - car cons try ...`) are one function, `prim`, dispatched on the `Op` enum. All Zig files other than `lang.zig` use normal `zig fmt` formatting.

`src/repl.zig` is the CLI/REPL: it installs the native stdlib (`src/stdlib_native.zig`, which also holds the whole-file natives `read-file write-file split load`; `load` is a `step` native that returns `.eval` for the parsed file), then loads `src/stdlib.lisp` (path relative to the repo root), then runs a file or the REPL. `src/gc.zig` is memory management. Errors are Zig error unions (`error.Lisp`); the raised Lisp value is in `lang.errv`.

**Evaluator**: explicit-stack machine, no native recursion per Lisp call, nesting level or callback, so there is no recursion limit other than memory. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, `apply` collecting the function and arguments on the operand stack `vs`, `native`). The machine state is a `Go`: evaluate a node, hand a value to the innermost frame, or apply the function at `vs[b]` to the arguments after it. Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame.
- **Natives that call back into Lisp** (`map`, `reduce`, `try`, `partial`, the trampoline and its thunks) are `Native.step` functions and run as `native` frames: their arguments stay on `vs` after the native (`vs[k.base]`), their state goes after them or in `k.i`. A step is invoked with `null` first, then with each callback's value, and returns the next `Go` via the helpers in `runtime.zig`: `finish` (pop, hand on a value), `callback` (call a function, its value comes back to the frame; sets `k.mark` like argument evaluation) or `tail` (replace the frame by a call, e.g. `partial`). Plain natives (`Native.plain`) just compute a value.
- **Errors** (`error.Lisp`, value in `lang.errv`) are caught by `exec`: `runtime.recover` drops the frames above the innermost `try` frame of this run and resumes it with the error value, which tail-calls the handler. Without one, the run truncates `ks`/`vs` to its base (`errdefer`) and the error propagates. The trampoline's "active" flag (`s.i` = index + 1 of its run frame) is validated against `ks`, so a run frame dropped by an error doesn't leave it stuck.
- **Macro expansion** (the compiler in lang.zig) is the only nested machine (`call` → `exec`): `in_macro` turns expansion off inside macros, so it nests one level.
- Parser, printer and freeing are iterative too.

**Values**: `V` is an 8-byte NaN-boxed `enum(u64)` (`runtime.V`): a number is its own double (NaN is canonicalised by `V.num`), everything else is a tagged payload in the quiet-NaN space (`nil`, bool, symbol/string, string literal, list, native function, closure). Build with `V.num/boolean/string/literal/listOf/fnOf/lamOf`, read with `tag()`/`is(tag)`/`asNum/asBool/asStr/asList/asFn/asLam`; compare with `==` only for identity or `V.nil` (use `.is(.n)` and `asNum` for numbers). A list is a length followed by its items (`Lst.items()`).

**Memory (`src/gc.zig`)**: stop-the-world mark-sweep on libc malloc. Every managed object (`alloc`/`new(T, extra, kind, init)`, not zeroed: constructors set every byte they use) has a one-word header (next object | kind | mark) and sits on one list; `perm` objects (parser symbols/literals, compiled nodes, root keys, root scope) are never collected. Nothing is counted: the evaluator loop calls `gc.collect()` at one safe point (the start of `.eval`, outside macro expansion) once `gc.due()` says about half as much as is live has been allocated (at least 2 MB), so no Zig local ever holds a value across a collection and natives may allocate freely. Roots (`gc.markRoots`): the `ks`/`vs` stacks (frames' scopes), every running machine's scope (`runtime.machines`), the global table, `runtime.pin`ned values (the AST that compiled nodes refer to) and `errv`. Marking and sweeping use worklists, never recursion; cycles are collected; allocation failure exits with `TinyLisp: out of memory`.
- Anything new that holds a value outside those roots (a Zig-side global, a cache) must be marked in `gc.markRoots`.
- Never call `collect` anywhere else, and never keep a `V` in a Zig local across an `.eval` step.
- **Scope recycling**: the scope of a call (`Env`, `runtime.bind`) is handed back to a free list (`runtime.release`) when the call ends (a tail call, or a return into a frame of another scope) unless a closure captured it (`Env.esc`, set by `runtime.lambda`). Recycling assumes only frames, `m.e` and closures hold a scope; the collector forgets the free list. This removes most allocation (about two thirds of all objects in microgpt).
- To stress the collector, build with a tiny `limit` in gc.zig (e.g. 2048 bytes) and run both suites.

## Language semantics

- **Macros**: any root-scope function named `macro/*` is applied to every AST node before it is compiled (raw node in, node out), once per node (see the compiler in lang.zig); defining or changing a `macro/*` bumps `runtime.epoch` so nodes compile again. Numbers, booleans and nil skip macros. `in_macro` prevents re-entrant expansion.
- Symbols and strings are the same type; string literals stay distinct in the AST (`.lit`) and evaluate to strings.
- `0` and `""` are falsy, `'()` is truthy; `eq?` treats an empty list as `nil`.
- `(lambda (a & rest) ...)`: the compiler drops `&` and sets `Proto.rest`; `runtime.bind` gives the last parameter the extra arguments as a list. The parser reads `'` `` ` `` `~` `~@` as `quote`, `quasiquote`, `unquote`, `unquote-splicing` forms (prefix markers on the `open` stack, negative entries); `quasiquote` itself is a Lisp macro in the stdlib (`quasi`).
- `defmacro` (stdlib, written without backquote): `(defmacro name (a & rest) body...)` defines `macro/name`, which checks the head, binds the parameters to the form's parts and returns the body's value. Code that runs inside a macro is never macro-expanded (`in_macro`), so macro bodies and the helper functions they call can't use macros; `defmacro` pre-rewrites backquote in its body (`quasi-walk`), the one exception. A template can't contain another one.
- Stdlib macros: `defn` (several body expressions become a `begin`), `fn` (a lambda with several body expressions), `->` (thread-first), `chain` (composes blocks; each block expression is evaluated once, as an argument of a wrapper lambda), `for` and `for/list` (expand to `map`; a pattern variable over `(zip xs ys)` becomes a multi-list `map`), `defrec`, `deftest`. `examples/autograd.lisp` adds `val` (infix arithmetic on values, Python's precedence) and `slots` (`(data v)` is `(at v 0)`).
- `map` takes several lists, `(map l1 ... ln f)`, and stops at the shortest; `range`, `zip` and `apply` are natives (a Lisp `zip`/`range` built with `cons`/`rest` is quadratic, since both copy); `flatten` is `(apply concat lst)` and `filter` builds on it.
- `defrec` rewrites self-calls into thunks and wraps the function with the native `trampoline`.

## Tests

Add a case whenever behaviour changes.
- `spec/specs.lisp`: `deftest` + `assert` (the test name is a string, so it can have spaces, and by convention reads `area: what it checks`; a symbol works too; `deftest` rewrites each `(assert expr)` to carry the test name and the quoted expression, so a failure prints both; `equal?` is a deep comparison), ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, 100k+ deep recursion through `map`/`reduce`/`partial`/`try` callbacks, errors unwinding them).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
