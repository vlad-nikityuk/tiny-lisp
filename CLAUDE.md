# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make                       # build ./tiny-lisp (Zig 0.17, ReleaseFast, links libc)
make test                  # spec/repl.py + spec/specs.lisp
make safe                  # ReleaseSafe build (bounds/overflow checks): ./tiny-lisp-safe
./tiny-lisp [-f file.lisp] [--debug]
zig fmt src/               # keep sources formatted
```

## Architecture

`src/lisp.zig` (values, parser, scopes, evaluator, primitives, CLI) imports `src/gc.zig` and `src/stdlib_native.zig`. The CLI installs the native stdlib, then loads `src/stdlib.lisp` (path relative to the repo root). Errors are Zig error unions (`error.Lisp`); the raised Lisp value is in the global `errv`.

**Evaluator**: explicit-stack machine, no native recursion per Lisp call or nesting level. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, application collecting arguments on the operand stack `vs`). Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame. Parser, printer and freeing are iterative too. The only native recursion left is natives calling back into Lisp (`map`, `reduce`, `try`, `partial`, macro expansion, trampoline): one `eval` re-entry per callback, capped at 8,000 (the 8 MB stack overflows at ~11k) with a catchable `ToyLisp: recursion too deep` error. `try` and the REPL restore `ks`/`vs`/`depth`/`in_macro` after an error.

**Memory (`src/gc.zig`)**: reference counts of *heap* references + per-call allocation regions, on libc malloc. Interface: `alloc`/`new` (logged, zeroed), `perm` (parser symbols/literals, root keys, root scope), `raw`/`rawFree` (owned buffers), `ret`/`rel` (count a heap reference), `mark`/`sweepKeep(m, keep, keep2)`. Every frame records a mark; a value returned to a frame is swept against it; tail calls and the trampoline use `resweep`, which keeps only the new body/scope (or result) and hands long-lived survivors (heap-referenced, survived 4 loop sweeps) to the enclosing region. Freeing uses a worklist, never recursion; allocation failure exits with `ToyLisp: out of memory`.
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
- `spec/specs.lisp`: `deftest` + `assert`, ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, callback depth guard).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
