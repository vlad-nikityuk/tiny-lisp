# Known limitations

This list matches [`BACKLOG.md`](../BACKLOG.md) and behaviour enforced in `src/`. It is not a roadmap; scheduled work is described there.

## Language and expansion

- **Self-expanding macros** — A macro that expands to a call of itself loops forever. There is no expansion depth limit or cycle detection (`BACKLOG.md`).
- **Nested quasiquote** — A `` ` `` template inside another `` ` `` is an error: `TinyLisp: nested quasiquote is not supported` (`stdlib.lisp` / `quasi`).
- **Compile nesting depth** — Code nested deeper than 5000 levels fails at compile time with `TinyLisp: expression is nested too deeply to compile (limit 5000)` (`lang/compile.zig`, `max_depth`). Data nesting (quoted lists, parser, expander, printer) is not limited the same way.

## Implementation quirks

- **`Proto.tried`** — If compiling a function body fails once, the flag is never reset; a fix to the source may require a new process or redefinition strategy (`BACKLOG.md`).
- **Platform coverage** — Linux is less verified: CI workflow, Makefile `sed -i.bak`, libuv bindings (sockaddr layout differs from macOS). libuv constants in `uv.lisp` are handwritten; load-time size checks run, but enums are not read from C headers.

## Performance documentation

- The microgpt timing table in the root [`README.md`](../README.md) was not re-measured after the bytecode VM work. Prefer [`bench/README.md`](../bench/README.md) for comparative numbers.

## Continuations and FFI

- Continuations cannot cross macro expansion, nested `eval.exec` machines, or FFI callbacks (`continuation.zig`). Details: [continuations.md](continuations.md).

## FFI (summary)

- No libffi: no struct-by-value, no variadic C functions; callbacks support at most four integer/pointer arguments via a fixed stub pool (64 slots). See [ffi.md](ffi.md).