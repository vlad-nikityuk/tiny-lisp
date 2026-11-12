# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make                       # build ./tiny-lisp (Zig 0.17, ReleaseFast, links libc)
make test                  # spec/repl.py + spec/specs.lisp
make safe                  # ReleaseSafe build (bounds/overflow checks): ./tiny-lisp-safe
./tiny-lisp [-f file.lisp] [--debug]
zig fmt --check src/       # lang.zig opts out; all other Zig sources stay formatted
```

## Architecture

`src/lang.zig` is the explicit-stack evaluator (`eval`, plus `call` for macro expansion), the parser (`parse`) and the evaluator's entry points. Keep it at **100 lines or fewer**, including comments and blank lines: it starts with `// zig fmt: off`, groups related statements, and keeps short section comments. Keep names meaningful and the total source small; move support code rather than hiding evaluator control flow.

`src/runtime.zig` holds values, the machine state (`K`, `Go`, `ks`, `vs`), reference-counted constructors, scopes and macro registration, primitives, the natives that call back into Lisp (as machine frames: `start`/`step`/`finish`/`callback`/`tail`, `try`, `recover`, the trampoline), and root-scope initialization. It raises errors through `lang.errv`; other modules import `runtime.zig` directly; `lang.zig` only exposes `eval`, `parse`, `out` and `errv`. Primitives (`+ - car cons try ...`) are one function, `prim`, dispatched on the `Op` enum. All Zig files other than `lang.zig` use normal `zig fmt` formatting.

`src/repl.zig` is the CLI/REPL: it installs the native stdlib (`src/stdlib_native.zig`, which also holds the printer behind `V.format`), then loads `src/stdlib.lisp` (path relative to the repo root), then runs a file or the REPL. `src/gc.zig` is memory management. Errors are Zig error unions (`error.Lisp`); the raised Lisp value is in `lang.errv`.

**Evaluator**: explicit-stack machine, no native recursion per Lisp call, nesting level or callback, so there is no recursion limit other than memory. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, `apply` collecting the function and arguments on the operand stack `vs`, `native`). The machine state is a `Go`: evaluate a node, hand a value to the innermost frame, or apply the function at `vs[b]` to the arguments after it. Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame.
- **Natives that call back into Lisp** (`map`, `reduce`, `try`, `partial`, the trampoline and its thunks) are `Native.step` functions and run as `native` frames: their arguments stay on `vs` after the native (`vs[k.base]`), their state goes after them or in `k.i`. A step is invoked with `null` first, then with each callback's value, and returns the next `Go` via the helpers in `runtime.zig`: `finish` (pop, hand on a value), `callback` (call a function, its value comes back to the frame; sets `k.mark` like argument evaluation) or `tail` (replace the frame by a call, e.g. `partial`). Plain natives (`Native.plain`) just compute a value.
- **Errors** (`error.Lisp`, value in `lang.errv`) are caught by `exec`: `runtime.recover` drops the frames above the innermost `try` frame of this run and resumes it with the error value, which tail-calls the handler. Without one, the run truncates `ks`/`vs` to its base (`errdefer`) and the error propagates. The trampoline's "active" flag (`s.i` = index + 1 of its run frame) is validated against `ks`, so a run frame dropped by an error doesn't leave it stuck.
- **Macro expansion** is the only nested machine (`call` → `exec`): `in_macro` turns expansion off inside macros, so it nests one level.
- Parser, printer and freeing are iterative too.

**Memory (`src/gc.zig`)**: reference counts of *heap* references + per-call allocation regions, on libc malloc. Interface: `alloc`/`new(T, extra, kind, init)` (logged, zeroed), `perm` (parser symbols/literals, root keys, root scope), `ret`/`rel` (count a heap reference), `mark`/`sweepKeep(m, keep)`. Every frame records a mark; a value returned to a frame is swept against it; tail calls and the trampoline use `resweep`, which keeps only the new body/scope (or result) and hands long-lived survivors (heap-referenced, survived 4 loop sweeps) to the enclosing region. Freeing uses a worklist, never recursion; allocation failure exits with `ToyLisp: out of memory`.
- Every value stored into the heap (list element, scope slot, global, closure capture, `Fn` data) goes through `rv()`/`gc.ret`; every overwritten heap value through `gc.rel`.
- Every string a value can point to comes from `mkstr`/`str` (never a Zig string literal: `ret` writes to the header in front of it).
- Values held only in frames / the operand stack / locals are not counted, so never sweep a region they live in.
- Check changes with `make safe` and both test suites on `./tiny-lisp-safe`.

## Language semantics

- **Macros**: any root-scope function named `macro/*` is applied to every AST node before evaluation (raw node in, node out). `in_macro` prevents re-entrant expansion. This dominates runtime.
- Symbols and strings are the same type; string literals stay distinct in the AST (`.lit`) and evaluate to strings.
- `0` and `""` are falsy, `'()` is truthy; `eq?` treats an empty list as `nil`.
- `defrec` rewrites self-calls into thunks and wraps the function with the native `trampoline`.

## Tests

Add a case whenever behaviour changes.
- `spec/specs.lisp`: `deftest` + `assert`, ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, 100k+ deep recursion through `map`/`reduce`/`partial`/`try` callbacks, errors unwinding them).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
