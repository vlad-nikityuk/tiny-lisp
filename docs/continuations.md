# Continuations (`call/cc`)

TinyLisp implements full re-entrant continuations: `call/cc` and `call-with-current-continuation` (`runtime/continuation.zig`, natives in `machine.zig`).

## Capture

Inside an `eval.exec` run, `call/cc` saves:

- Frames on `ks` from `Machine.base` up to (but not including) the `call/cc` frame
- Values on `vs` from `vbase` up to the `call/cc` frame's `base` — as if `call/cc` had already returned

The continuation is a native `Fn` with extra bytes: `kbase`, `vbase`, `nframes`, `nvalues`, then copied `Frame` array and `V` array. The collector traces these via `continuation.markCont` (`contExtraBytes` must match allocation).

Every `Env` and `iter_env` in the snapshot is `hold`/`captured` so tail-call and loop scope recycling cannot reuse them after capture.

## Invoke

Calling the continuation truncates the active run to the saved `kbase`/`vbase`, copies the suffix back, and returns one value to the resuming code (`ret` with one argument). Zero arguments → `nil`; more than one → error.

A continuation saved in one top-level form can be invoked from a later form; the rest of the captured form runs and its value becomes the value of the current top-level form (`examples/continuations.lisp`).

## Limits

Capture or invoke is an error when:

- `machine.macro_depth > 0` — inside macro expansion
- `machine.machines.items.len > 1` — nested `eval.exec` (e.g. another machine active)
- `machine.callback_depth > 0` — inside an FFI callback

So continuations cannot cross macro expansion or FFI callbacks. They are intended for user-level control flow within a normal top-level run, not for low-level FFI or expander internals.

## Relation to `try` and the trampoline

Errors use frame truncation to `try` handlers, not continuations. `defrec` uses the trampoline native, not `call/cc`. Replacing those with `call/cc` would not simplify the machine and would add cost to code that never uses continuations (`CLAUDE.md`).

## Example

```lisp
(print (+ 1 (call/cc (lambda (k) (k 5)))))
```

```bash
echo '(print (+ 1 (call/cc (lambda (k) (k 5)))))' | ./tinylisp
# 6
```

Tests: `spec/continuations.lisp`.