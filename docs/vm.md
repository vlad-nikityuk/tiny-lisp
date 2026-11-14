# Bytecode virtual machine

All user code runs as stack bytecode (`src/vm/`). The tree interpreter was removed; `compiler.zig` and `exec.zig` are the only execution engine.

## When code compiles

| Situation | When |
|---|---|
| Top-level form | Before it runs (`compiler.top`, no parameters, root scope) |
| Function (`Proto`) | On first call (`compiler.ready`); again if epoch stamp is stale |

Compilation refuses bodies already marked failed (`Proto.tried`). Nesting limit: 5000 (`lang/compile.zig`).

## Fixed slots

`scan.zig` collects names: parameters, then every `define` in the body (not in nested lambdas). `scope.bind` allocates an `Env` with one slot per name; defines start as `V.unbound`.

Bytecode reads locals with `local` / `local_checked` (the latter when the compiler cannot prove the define already ran). Assignments use `setlocal`. Names from enclosing scopes or globals use `outer` / `setouter` with cached `(hops, index)` in the instruction operand `b` after the first lookup.

Top-level thunks have **no** slots: globals use `outer` / `assign` via `scope.set`.

## Opcode overview

Documented in `bytecode.zig`. Groups:

- **Stack values** — `konst`, `local`, `outer`, `global`, `lambda`, `pop`
- **Stores** — `setlocal`, `setouter`, `setglobal`, `assign`, `storelocal` (inlined callee args)
- **Control** — `jmp`, `jmpf`, `andj`, `orj`, `call`, `tailcall`, `ret`, `empty` (illegal `()`)
- **Primitives** — `add`, `sub`, …, `prim1`, fused `*_lk`, `*_ll`, `*_sk`, `*_sl`, `vset` / `vset_ll`
- **Loops** — `each`, `map`, `eachnext`, `mapnext` for `(each list λ)` and `(map list λ)` with one list (and guarded top-level `(each (range n) …)`)

Fused instructions encode “local or stack” × “local or constant” in the low/high halves of `b`.

## Primitive fusion

When a call's operator is a **global** still bound to the builtin (`+`, `at`, …) and operands are constants or locals, the compiler emits fused opcodes instead of `call`. If operands are dynamic (e.g. two arbitrary expressions), it falls back to `prim` + `slow` path in `exec.zig`.

Rebinding `+` (or binding it locally in a function that inlined it) bumps `scope.epoch` and invalidates bytecode that assumed the native.

## Inlining (`genInline`)

Small global functions with no closures may be copied into the caller with fresh slots; free names become `global` / `setglobal`. Replacing such a function sets `Proto.inlined` and bumps epoch so callers recompile on next entry.

Inlined callees are not inlined into **top-level** thunks.

## VM-driven loops

For `(each lst (lambda (x) body))` or single-list `map` inside a compiled function, the compiler emits loop opcodes. A `.loop` frame on `ks` holds list progress on `vs` and reuses `iter_env` per iteration unless a closure captured it.

The lambda that is the last operand of `each`/`map` may be marked `Proto.guard` so its scope is not marked captured for closure recycling (loop-body-only).

Top-level `each` / `map` with a constant global name gets a **guard**: at run time, if the name is still the expected native, the bytecode loop runs; otherwise jump to `fail_pc` and use a normal call. `(range n)` loops set the range guard bit.

## Epoch invalidation

`Bytecode.stamp` records `scope.epoch` at compile time. Epoch increases when:

- A primitive or `each`/`map` name with `Sym.inlined` is rebound
- An inlined function is replaced
- A function binds such a name locally

Stale bytecode is discarded on the next call; execution never runs out-of-date fused primitive assumptions.

## Tail calls

- **`tailcall`** — In a function body, replace current frame/scope (when recyclable) with the callee.
- **`.apply`** — Machine-level tail apply from `eval`.
- **`defrec`** — Trampoline turns direct self-calls into thunks; the trampoline driver tail-applies in a loop.

Self tail call in a scope with no `captured` environments reuses the same `Env` and clears define slots to `unbound` for the new iteration.

## Interaction with GC

`exec` may trigger `gc.collect()` on self-tail backedges and loop iterations when `gc.due()` (roughly half of live size allocated, at least 2 MB). Before collection, the executor publishes `vs.items.len` and the active scope so roots are correct.

## Example

Arithmetic fuses when operands are simple:

```lisp
(defn sq (x) (* x x))
(print (sq 4))
```

Run: `echo '(defn sq (x) (* x x)) (print (sq 4))' | ./tinylisp` → `16`.

For guard and loop behaviour, see `spec/specs.lisp` cases prefixed with `vm:`.