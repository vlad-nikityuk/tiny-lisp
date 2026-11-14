# Memory and values

## NaN-boxed `V`

All Lisp values fit in 8 bytes (`runtime/value.zig`):

- **Numbers** — IEEE double bits; NaN canonicalised.
- **Other tags** — Quiet NaN box with 3-bit tag in bits 48–50: `nil`, bool, symbol/string, string literal (`.lit`), list, native fn, closure (`lam`).

`V.unbound` (tag 0) fills defined-but-not-yet-run slots; the printer must not see it in normal output.

Identity comparison: use `eq?` for values; `V.==` is for identity / `nil` only.

## Managed objects

Allocated with `gc.alloc` / `gc.new` (header + payload, not zeroed):

| Kind | Typical use |
|---|---|
| `perm` | Interned symbols, literals, nodes, root scope — never collected |
| `str` | Heap strings |
| `list` | `Lst` — length + inline items |
| `func` | `Fn` natives and continuations |
| `lam` | Closure: `Proto` + captured `Env` |
| `env` | Scope table |

Lists are immutable except `vset!`. `cons` / `cdr` copy.

## Mark-sweep GC

Stop-the-world, single list of objects, `malloc`/`free` (`gc.zig`):

1. **Trigger** — `gc.due()` after ~half of estimated live bytes allocated (minimum threshold 2 MB in normal builds; tests also use 2 KB floor).
2. **Roots** — `gc.markRoots`: `ks`/`vs` frames and their scopes, all registered machines' scopes, global table, `gc.pin`ned AST, `errv`, continuation extras, FFI callback roots, etc.
3. **Mark** — Worklist tracing, no C recursion.
4. **Sweep** — Unmarked objects freed; cycles collected.

**Safe points** — Collection runs at `.vm` transitions in `eval` and at VM loop back-edges (self-tail, loops), not on every allocation.

**Rules for Zig code** — Do not hold the only pointer to a managed object in a local across a `.vm` step unless it is also rooted. Natives may allocate freely; roots must see live values.

## Pinned values

Compiled `Node` trees reference source lists; those lists are `gc.pin`ned so macros and compilation cannot collect them. Closures point at permanent `Proto` nodes.

## Scope recycling

`Env` objects for finished calls return to a pool (`scope.release`) when `recyclable` and not `captured`. `bindWith` reuses pooled envs of matching capacity. Closures call `scope.lambda` / `hold` to mark scopes captured; they are not recycled.

`markRoots` clears env pools at collection start (pooled scopes are not roots until handed out again).

**Loop optimisation** — A loop-body lambda guarded as `each`/`map` operand does not capture its enclosing scope for closure purposes, so outer calls stay recyclable during `for`/`map` bytecode loops.

## Out of memory

Allocation failure prints `TinyLisp: out of memory` and exits.

## Stress testing

`make test` also runs suites with a low GC threshold (2048 bytes) to force frequent collections.