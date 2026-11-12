# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make                       # build ./tiny-lisp
make test                  # spec/repl.py + spec/specs.lisp + the 100-line check on src/lisp.c
make asan                  # AddressSanitizer build: ./tiny-lisp-asan
make test-zig              # build ./tiny-lisp-zig (Zig 0.17) and run the same suites
./tiny-lisp [-f file.lisp] [--debug]
```

## Architecture

`src/lisp.c` must stay **<= 100 lines** (enforced by `make test` and CI). It `#include`s `src/gc.c` and `src/stdlib_native.c`, which are not counted. The CLI installs the native stdlib, then loads `src/stdlib.lisp` (path relative to the repo root).

**Evaluator**: explicit-stack machine, no C recursion per Lisp call or nesting level. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, application collecting arguments on the operand stack `vs`). Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame. Parser, printer and freeing are iterative too. The only C recursion left is natives calling back into Lisp (`map`, `reduce`, `try`, `partial`, macro expansion, trampoline): one `eval` re-entry per callback, capped at 12,000 with a catchable `ToyLisp: recursion too deep` error. Errors use `setjmp`/`longjmp`; `try` and the REPL restore `kn`/`vn`/`depth`.

**Memory (`src/gc.c`)**: reference counts of *heap* references + per-call allocation regions. Interface: `gc_alloc(n, kind)`, `gc_perm(n)` (parser symbols/literals, root keys), `gc_raw`/`gc_raw_free` (owned buffers), `ret`/`rel` (count a heap reference), `gc_mark`/`gc_sweep(m, keep, keep2)`. Every frame records a mark; a value returned to a frame is swept against it; tail calls and the trampoline use `gc_resweep`, which keeps only the new body/scope (or result) and hands long-lived survivors (heap-referenced, survived 4 loop sweeps) to the enclosing region. Freeing uses a worklist, never recursion; allocation failure exits with `ToyLisp: out of memory`.
- Every value stored into the heap (list element, scope slot, global, closure capture, `Fn` data) goes through `RV()`/`ret`; every overwritten heap value through `rel`.
- Every string a value can point to comes from `mkstr`/`own` (never a C literal or raw malloc).
- Values held only in frames / the operand stack / C locals are not counted, so never sweep a region they live in.
- No VLAs sized by data (use the heap).
- Check changes with `make asan` and run both test suites on `./tiny-lisp-asan` (the callback-depth test can overflow under ASan's larger frames).

**Zig port (`src/zig/`)**: a 1:1 port of the three C files (same evaluator, GC and semantics), written readably and not line-limited. Keep both in sync when behaviour changes. Differences: errors are Zig error unions (`error.Lisp` + `errv`) instead of `longjmp`, and the callback depth cap is 8,000 (Zig frames are bigger; it overflows the 8 MB stack at ~11k). Check memory-safety-sensitive changes with `zig build-exe -OReleaseSafe -lc src/zig/lisp.zig`.

## Language semantics

- **Macros**: any root-scope function named `macro/*` is applied to every AST node before evaluation (raw node in, node out). `in_macro` prevents re-entrant expansion. This dominates runtime.
- Symbols and strings are the same type; string literals stay distinct in the AST (`LIT`) and evaluate to strings.
- `0` and `""` are falsy, `'()` is truthy; `eq?` treats an empty list as `nil`.
- `defrec` rewrites self-calls into thunks and wraps the function with the native `trampoline`.

## Tests

Add a case whenever behaviour changes.
- `spec/specs.lisp`: `deftest` + `assert`, ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, callback depth guard).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
