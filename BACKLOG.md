# Backlog

The owner's plan for tiny-lisp, in order. Status as of 2026-11-14. PR: #38 (`perf-vm`).

## Done (pushed to PR #38)

- **Performance work**: geometric mean of tinylisp / CPython went from 2.32x to 0.55x (bytecode VM, fused instructions, loops run by the bytecode, inlining, scope reuse). See `bench/README.md`.
- **Simplification and restructure**: `src/` split by responsibility (`runtime/`, `lang/`, `vm/`, `lib/`); no line cap on files; both tiers kept until stage 3.
- **Stage 1**: macros are expanded eagerly per top-level form; `defmacro` is an expander form, top level only; nested quasiquote is an error; `eval` runs at top level.
- **Stage 2**: function bodies have hoisted local names (`define` anywhere in a body makes the name local to the whole body); reading a local before it is defined is the error `x is used before it is defined`; `set!` of an unknown name is an error; `load` and `eval` run at top level.
- **Stage 3**: the tree interpreter is removed. One engine: the bytecode VM. Top-level forms compile to bytecode too. Makefile targets: `make test`, `make lint`, `make check-all`, `make fmt`, `make bench`.
- **call/cc**: full re-entrant continuations (`call/cc`, `call-with-current-continuation`); see `src/runtime/continuation.zig`, `spec/continuations.lisp`, `examples/continuations.lisp`.
- **CFFI + libuv**: register-split C calls, callback pool, `define-library`, libuv bindings with load-time type-id checks; stable `uv-loopback-run` and `spec/uv-integration.lisp` (three HTTP requests on one loop); teaching `examples/uv-server.lisp` / `uv-client.lisp`.
- **Node-like stdlib (`node.lisp`)**: libc fs/path/process/os/time on top of FFI (load on demand); `spec/node.lisp`, `examples/node-tour.lisp`.

## In progress

(nothing)

## Next

1. **Stage 4: static variable addresses.** With no scope that can grow at run time, compile every variable reference to a fixed (hops, index) and drop names from scopes; remove the quickened lookup caches. Expected to simplify and speed things up.
2. **Stage 5: folder renames** as the owner proposed: `syntax/` (parser, ast, expand), `bytecode/` (format, scan, compiler, interpreter), `builtins/` (natives + source + stdlib.lisp), `runtime/` (value, gc, scope, primitives); rename `node` to `ast`; decide where `machine.zig` lives.

## Known limitations and ideas (not scheduled)

- A macro that expands to itself loops forever (no expansion limit).
- Nested quasiquote is an explicit error (levels are not implemented).
- Code nested deeper than 5000 levels gives a compile error (the bytecode compiler recurses).
- `Proto.tried` is never reset for a body whose compile failed once.
- The microgpt table in `README.md` was not re-measured after the performance work.
- Unverified on Linux: the CI workflow, the `sed -i.bak` in the Makefile, the libuv bindings (sockaddr layout differs from macOS).
- libuv `define-library` constants are handwritten; `uv.lisp` checks sizes at load but does not read enums from C headers.

## Process notes

- Verify with `make clean && make check-all` (a stale `./tinylisp` hid failures twice). `make test` also runs the specs under a collector-stress build (2 KB minimum threshold).
- Implementation is done with `cursor-agent` (Composer 2.5), reviews with Grok (`grok-4.7-xhigh`) in a throwaway `git worktree` under `/tmp`; Claude and Codex budgets are limited. Do not push before the check passes.