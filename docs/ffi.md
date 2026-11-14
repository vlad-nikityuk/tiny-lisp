# Foreign function interface

FFI lives in `src/lib/ffi.zig` (natives, always installed; zero cost if unused) and `src/lib/ffi.lisp` (marshaling and `define-library`). Optional bindings: `uv.lisp`, `node.lisp`.

## Design: register-split calls (no libffi)

On AArch64 AAPCS64 and x86-64 SysV, integer/pointer and floating-point arguments use separate register banks. TinyLisp casts C functions to `fn(i64×8, f64×8) callconv(.c)` and routes arguments to the right bank — no libffi dependency.

**Limits:**

- No struct-by-value
- No variadic C functions
- `f32` widened to `f64`
- Pointers are Lisp numbers (exact integers up to 2^53; larger addresses use bitcast)

`ffi-dlopen-self` opens `libSystem.B.dylib` or `libc.so.6`.

## Natives (Zig)

| Native | Role |
|---|---|
| `ffi-dlopen`, `ffi-dlopen-self`, `ffi-dlsym` | Load symbols |
| `ffi-call-i64`, `ffi-call-f64`, `ffi-call-void` | Invoke |
| `ffi-malloc`, `ffi-free`, `ffi-peek`, `ffi-poke` | Memory |
| `ffi-cstr`, `ffi-string-at` | Strings |
| `ffi-register-callback`, … | Callback pool |

Errors in Lisp callbacks are stored in `machine.ffi_pending_err` (a GC root) and re-raised after C returns (`ffi-take-error`); they must not unwind through C. `call/cc` is forbidden while `machine.callback_depth > 0`.

Callback pool: **64** stubs; each passes four `i64` args and returns one `i64` (up to four Lisp callback args).

## Lisp layer

Load the DSL:

```lisp
(load "src/lib/ffi.lisp")
(define-library libc self
  (function strlen ((s string)) int))
(print (strlen "hi"))
```

Run from repo root: `./tinylisp -f` with the above in a file → `2`.

`define-library`:

- `paths-or-self` — `self` or a quoted list of `.so`/`.dylib` candidates
- Declarations: `(constant NAME value)`, `(function NAME ((arg type)…) rettype)`
- Types: `int`, `uint`, `long`, `ulong`, `size_t`, `pointer`, `string`, `double`, `float`, `bool`, `void`, `(callback (argtypes…) rettype)`
- Handle variable: `NAME-lib` (e.g. `libc-lib`)

`ffi-build-call` takes tagged `(value type)` lists; use `nil` for empty arg lists, not bare `()` in argument position (`ffi.lisp` comment).

Compiler tables cap at **256** slots / `u16` indices (`spec/vm-huge-top.lisp`). Signed `int`/`int32` returns are sign-extended.

Marshaling uses locals in `ffi-build-call-impl`, not a global accumulator, so GC during re-entrant marshaling cannot collect temps.

## libuv

`src/lib/uv.lisp` binds libuv via `define-library`. Type-id constants are handwritten; load-time checks verify struct sizes. `spec/uv-integration.lisp` and `examples/uv-loopback.lisp` exercise loopback HTTP when libuv is installed. sockaddr layout may differ on Linux vs macOS (see [limitations.md](limitations.md)).

## `node.lisp`

Node-like `fs` / `path` / `process` helpers on libc through FFI (load on demand). `spec/node.lisp`, `examples/node-tour.lisp`.

## Why not libffi

libffi adds dependency and complexity for an educational codebase. The register-split trick covers the teaching use cases (libc, libuv) with explicit limits documented in tests (`spec/ffi*.lisp`).