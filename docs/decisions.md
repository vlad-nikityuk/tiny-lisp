# Design decisions

Each entry: **context**, **decision**, **alternatives rejected**. Details are in `src/` and `CLAUDE.md`; benchmarks in `bench/README.md`.

## One engine: bytecode VM only

**Context** — Early versions used a tree-walking evaluator; performance and duplication cost grew.

**Decision** — Remove the tree interpreter (stage 3). Every function and top-level form compiles to stack bytecode (`vm/compiler.zig`, `vm/exec.zig`).

**Rejected** — Dual-tier (tree + VM), interpreting only hot paths. Extra complexity and two semantics to test.

## Eager macro expansion per top-level form

**Context** — Macros must see prior definitions; expansion must not run user code from the wrong scope.

**Decision** — Read one top-level form, expand it entirely (including lambda bodies), then compile and run. `defmacro` is handled only in `expand.zig` at top level.

**Rejected** — Expand on demand at call sites only (macros in nested code would order incorrectly). Recursive expander on the C stack (stack overflow on deep data).

## Hoisted body-local `define` names

**Context** — Python-like function locals vs traditional Lisp `let`/`letrec` only.

**Decision** — Any `define` in a function body creates a slot for the whole body; unbound until executed; early read is an error. Top-level `define` stays global without hoisting into expressions.

**Rejected** — Implicit `nil` before define (hides bugs). Full `letrec` only (more verbose for learners used to Python).

## Explicit machine stacks, no native recursion per Lisp call

**Context** — TypeScript version overflowed the JS stack; C version needed predictable memory.

**Decision** — `ks` (frames) and `vs` (values) on the heap; `eval.run` loop; compiler depth cap 5000 for Zig stack safety.

**Rejected** — Native Zig recursion for Lisp calls (platform stack limits). Trampolines everywhere (kept only for `defrec`).

## Mark-sweep at safe points, not reference counting

**Context** — Closures, cycles, and macros need simple memory story.

**Decision** — malloc + mark-sweep when allocation crosses threshold; roots include stacks and globals; iterative mark.

**Rejected** — Refcount only (cycles). Per-call arena (closures outlive calls). Size-class allocator in GC (**measured slower** than macOS `malloc` on bench — not shipped).

## NaN boxing for `V`

**Context** — Uniform 8-byte values on stack and in scopes.

**Decision** — Double tags for numbers; boxed payload for other types.

**Rejected** — Tagged union larger than 8 bytes on 64-bit stacks (memory). Separate number stack (splits VM).

## Fixed scope slots + cached `outer` hops

**Context** — Variable lookup dominated hot code.

**Decision** — Scan parameters/defines at compile time; bytecode uses slot indices; first `outer` records `(hops, index)` in the instruction.

**Rejected** — Name lookup every read. Extra quickening caches beyond instruction operands (**no bench gain**). Stage 4 may compile fixed addresses for all refs (`BACKLOG.md`).

## Fused primitives and small-function inlining

**Context** — Bench showed time in arithmetic and small helpers.

**Decision** — Fuse global primitive calls with local/const operands; inline small global functions without closures; epoch bump on rebind.

**Rejected** — Three-operand `+` fusion (no gain). Fused compare-and-branch (not kept). Calls staying inside `exec` without machine frames for all calls (no gain).

## VM `each`/`map` loops

**Context** — `map`/`for` heavy in microgpt and benches.

**Decision** — Single-list `each`/`map` with loop lambdas compile to `each`/`map` opcodes; guard top-level names at run time.

**Rejected** — Always calling the `map` native (slower). Only counting loops (general list walk needed).

## No libffi

**Context** — Teaching C interop on macOS/Linux without shipping libffi.

**Decision** — Register-split `ffi-call-*`; handwritten `define-library`; callback pool with fixed arity.

**Rejected** — libffi (dependency, struct/variadic story). Hand-written assembly per call (portability).

## Continuations as copied stacks, not one-shot only

**Context** — Educational completeness; `examples/continuations.lisp`.

**Decision** — Full `call/cc` with snapshot of `ks`/`vs` suffix; limits at macro/FFI boundaries.

**Rejected** — Implementing only `reset`/`shift` (different API). Using `call/cc` for all errors/`defrec` (machine stays explicit).

## Iterative parser, printer, expander

**Context** — Deep lists and macro output must not overflow native stack.

**Decision** — Explicit stacks in parser, expander, printer, GC mark/sweep.

**Rejected** — Recursive parser for s-expressions only (depth limits differ for data vs code).

## Things benching ruled out

From `bench/README.md` (not in the implementation):

- Size-class GC allocator
- Extra outer lookup caches beyond bytecode operands
- Three-operand arithmetic fusion
- Running all inter-function calls inside `vm.exec` without machine involvement
- Dedicated bytecode for generic statement sequences
- Fused compare-and-branch

Improvements are kept only when `make test` passes and `make bench` does not regress (`CLAUDE.md`).