# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## This is an educational project

Readability and understandability come first: someone should be able to read the source to learn how a small Lisp is built. Prefer the simple, explicit design over the clever one, name things for what they mean, keep comments for the why, keep modules small and each with one job, and delete code that does not pay for itself. Both execution tiers stay: the tree evaluator (`src/lang.zig`) is the reference semantics and the bytecode tier (`src/bytecode.zig` compiles, `src/vm.zig` runs) is the fast path; simplify around them, not by removing either. A speed-up or a simplification is only kept if the tests pass and `make bench` does not get slower (see Tests).

## Commands

```bash
make                       # build ./tinylisp (Zig 0.17, ReleaseSafe: bounds/overflow checks, links libc)
make test                  # spec/repl.py + spec/specs.lisp
make test-tree             # the same tests with the bytecode tier off: both tiers must agree
make test-gc               # the same tests with a collection every 2 KB: stresses the collector's roots
make bench                 # bench/run.py: 18 programs in Python and tinylisp, same output checked, times compared (ARGS="-n 1 nbody")
make fast                  # ReleaseFast build without the checks (a previously measured ~4% faster): ./tinylisp-fast
./tinylisp [-f file.lisp] [--debug]
zig fmt --check src/       # every Zig source is zig fmt clean
```

## Architecture

`src/` is one entry point and four units; each file has one job:

```
src/repl.zig              the entry point: CLI and REPL
src/runtime/              what both tiers and the natives share
    value.zig             V (NaN-boxed), the objects it points to (Lst, Fn, Lam), constructors and tests, the printer, the error value
    gc.zig                the memory manager: allocation, mark-sweep, the roots, pinned values
    scope.zig             Env, the global table, epoch/shape, lookup and assignment, closures, scope recycling
    node.zig              compiled-code data both tiers use: Node, Code, Prim, Ref, Def, Proto, Guard, Sym
    machine.zig           Frame, Machine, Go, the ks/vs stacks, natives that call back into Lisp (start/step/finish/callback/tail), try/recover, the trampoline
    primitives.zig        + - car cons ...: `prim` specialised per Op, `numeric`, and `fast`/`fast1`, the in-place forms both tiers use
src/lang/                 the language: the reference semantics
    parser.zig            text -> AST (lists of values), iteratively
    compile.zig           AST -> nodes, lazily: intern, form, call recognition, macro expansion (force)
    eval.zig              the explicit-stack evaluator (eval/exec/run): runs nodes, and hands compiled functions to vm/
src/vm/                   the second tier, the fast path for function bodies
    bytecode.zig          the format: Opcode (each instruction documented), Ins, Bytecode
    compiler.zig          nodes -> bytecode (scan, gen, inlining), `ready`
    exec.zig              the executor
src/lib/                  the standard library
    natives.zig           map each reduce apply range zip print, the file natives and load
    source.zig            read a whole file as one program (for load and the REPL's -f)
    stdlib.lisp           the Lisp part, loaded at start (path relative to the repo root)
```

**Dependency direction**: `runtime/` ← `lang/parser`, `lang/compile` ← `vm/` ← `lang/eval` ← `lib/` ← `repl.zig`; a file imports the specific module it uses, there are no forwarding files. `runtime/` imports nothing from `lang/`, `lib/` or `vm/`, except the type `vm/bytecode.Bytecode`, which `Proto`, `Frame` and `Go` point to and `scope.bind` reads the slot names from. Inside `runtime/`, `gc.zig` and the object owners refer to each other (the collector allocates their objects and traces their roots), and `value.zig` names the other parts' types as pointers. The one real cycle above `runtime/`: `lang/compile` runs the machine (`eval.exec`) to expand macros, and `lang/eval` compiles nodes on demand (`compile.force`). `vm/` uses `lang/compile` (`force`, `current`, `in_macro`) but never `lang/eval`; `lang/eval` dispatches into `vm/` (`compiler.ready`, `exec.exec`).

Keep names meaningful and the total source small; keep the evaluator's control flow visible in `lang.run` and `vm.exec` rather than hidden behind helpers. All Zig sources are `zig fmt` clean. Errors are Zig error unions (`error.Lisp`); the raised Lisp value is in `lang.errv`. `lang.zig` exposes `eval`, `out` and `errv`, and to the second tier and `load` also `force`, `current`, `in_macro` and `stub`.

**The tree compiler** (lang.zig) turns the AST into typed nodes (`runtime.Node`/`Code`: constant, variable, if, begin, &&/||, define/set!, lambda, call, prim) lazily, the first time a node is evaluated: macro/* expansion happens there (once per node; `scope.epoch` is bumped when a macro/* changes and nodes compile again; `in_macro` turns expansion off inside macros), symbols are interned (`Sym`; scope keys compare by address; a name no scope has ever bound (`Sym.local`) is looked up in the global table directly, with the slot cached in the node). Nodes, their arrays and symbols are permanent (`gc.perm`); the AST they came from (and macro expansions) is pinned for good with `runtime.pin`, so frames and closures (`Lam.proto`) point at nodes freely.

**Primitive calls in place**: a one- or two-operand call whose head is a global bound to `+ - * / mod < > <= >= eq? at` (two operands) or `not abs floor sqrt exp log cos` (one) compiles to `Code.prim` (`call` in lang.zig). `lang.atom` computes it with `primitives.fast` when its operands are constants, variables or such calls up to 3 levels deep (no frame, no call); it falls back to the plain call `Prim.c` if the name was rebound (`sym.local` or the global slot changed), an operand cannot be evaluated within the bounded in-place descent (`Prim.slow`) or the operands are not plain numbers/list+index. `atom`'s slow part (`inplace`) must stay out of line: inlining it into `run` made everything slower.

**Tier 2** (`src/bytecode.zig` compiles, `src/vm.zig` runs): the first call of a function (a `Proto`) compiles its whole body to a stack bytecode (`bytecode.Bytecode`/`Ins`/`Opcode`, each instruction documented there) and its parameters and defines get **fixed slots** in the call's scope (`scope.bind` creates them all up front, defines as nil). `lang.run` has a `.vm` step (`vm.exec` runs instructions until it needs the machine: a call, or a return) and a `vm` frame kind that resumes the code at the instruction after a call. Tail calls are `.apply` as before; a function calling itself in tail position in a scope no closure holds (`Env.captured`) reuses that scope. Locals are `local`/`setlocal` slot accesses; other names go through `outer`/`setouter`, which remember `(hops, index)` after the first lookup (the scopes passed must be tier-2 scopes, so their layout is fixed) and only check the key. Primitive calls (`+ - * < > <= >= eq? at` and the rest of `Prim`) are instructions, fused with local/constant operands where possible; `vset!`, `each` and `map` have their own instructions. A call of a small global function without closures (`genInline`) is compiled into the caller, with slots of its own and its free names read as globals (`global`/`setglobal`); replacing such a function bumps `epoch` (`Proto.inlined`, `scope.replace`). `(each list (lambda (x) ...))` (so `for`) and `(map ...)` (so `for/list`) with one list are a **loop run by the bytecode**: a `loop` frame keeps the list position on the value stack and the last iteration's scope (`Frame.iter_env`, marked by the collector), which the next iteration reuses unless a closure captured it; the loop body is its own bytecode and returns to the loop with the instruction `ret`. Compiled code is valid for a compiler stamp (`lang.current()`); rebinding a primitive or `each` (any `Sym.inlined`) bumps `epoch`, which compiles everything again.
- What stays with the tree evaluator (the reference semantics): a body the compiler rejects (nested too deep; a `define` of a name that was used earlier in the body, or used after the branch it was defined in; an error while expanding macros), anything run while a macro expands (`in_macro`).
- Differences from the tree evaluator that are on purpose: the whole body is macro-expanded when the function is first called (not node by node as it runs), and a primitive rebound while a function that inlines it is running is seen only by calls started afterwards.
- Tests: `spec/specs.lisp` has "tier 2: ..." cases; `make test-tree` runs both suites with the tier off (`enabled` in bytecode.zig) to check they agree.

**Evaluator**: explicit-stack machine, no native recursion per Lisp call, nesting level or callback, so there is no recursion limit other than memory. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, `apply` collecting the function and arguments on the operand stack `vs`, `native`). The machine state is a `Go`: evaluate a node, hand a value to the innermost frame, or apply the function at `vs[b]` to the arguments after it. Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame.
- **Natives that call back into Lisp** (`map`, `reduce`, `try`, `partial`, the trampoline and its thunks) are `Native.step` functions and run as `native` frames: their arguments stay on `vs` after the native (`vs[k.base]`), their state goes after them or in `k.i`. A step is invoked with `null` first, then with each callback's value, and returns the next `Go` via the helpers in `runtime.zig`: `finish` (pop, hand on a value), `callback` (call a function, its value comes back to the frame) or `tail` (replace the frame by a call, e.g. `partial`). Plain natives (`Native.plain`) just compute a value.
- **Errors** (`error.Lisp`, value in `lang.errv`) are caught by `exec`: `runtime.recover` drops the frames above the innermost `try` frame of this run and resumes it with the error value, which tail-calls the handler. Without one, the run truncates `ks`/`vs` to its base (`errdefer`) and the error propagates. The trampoline's "active" flag (`s.i` = index + 1 of its run frame) is validated against `ks`, so a run frame dropped by an error doesn't leave it stuck.
- **Macro expansion** (the compiler in lang.zig) is the only nested machine (`call` → `exec`): `in_macro` turns expansion off inside macros, so it nests one level.
- Parser, printer and freeing are iterative too.

**Values**: `V` is an 8-byte NaN-boxed `enum(u64)` (`runtime.V`): a number is its own double (NaN is canonicalised by `V.num`), everything else is a tagged payload in the quiet-NaN space (`nil`, bool, symbol/string, string literal, list, native function, closure). Build with `V.num/boolean/string/literal/listOf/fnOf/lamOf`, read with `tag()`/`is(tag)`/`asNum/asBool/asStr/asList/asFn/asLam`; compare with `==` only for identity or `V.nil` (use `.is(.n)` and `asNum` for numbers). A list is a length followed by its items (`Lst.items()`).

**Memory (`src/gc.zig`)**: stop-the-world mark-sweep on libc malloc. Every managed object (`alloc`/`new(T, extra, kind, init)`, not zeroed: constructors set every byte they use) has a one-word header (next object | kind | mark) and sits on one list; `perm` objects (parser symbols/literals, compiled nodes, root keys, root scope) are never collected. Nothing is counted: the evaluator calls `gc.collect()` at `.eval` and `.vm`, and the VM at self-tail-call backedges and loop iterations once `gc.due()` says about half as much as is live has been allocated (at least 2 MB), with every live managed value reachable from a root; natives may allocate freely. Roots (`gc.markRoots`): the `ks`/`vs` stacks (frames' scopes), every running machine's scope (`runtime.machines`), the global table, `runtime.pin`ned values (the AST that compiled nodes refer to) and `errv`. Marking and sweeping use worklists, never recursion; cycles are collected; allocation failure exits with `TinyLisp: out of memory`.
- Anything new that holds a value outside those roots (a Zig-side global, a cache) must be marked in `gc.markRoots`.
- At collection, publish the VM stack pointer in `vs.items.len` and keep the active scope in the registered machine. A Zig local may survive collection only if its managed object is also reachable from a root; never rely on a local alone across an `.eval` step.
- **Scope recycling**: the scope of a call (`Env`, `scope.bind`) is handed back to a free list (`scope.release`) when the call ends (a tail call, or a return into a frame of another scope) if it is still `Env.recyclable` (`scope.lambda` clears that when a closure captures it). Recycling assumes only frames, `m.e` and closures hold a scope; the collector forgets the free list. A closure (`scope.lambda`) marks its scope and every enclosing one as `captured` and no longer recyclable. The exception is the lambda that is the last operand of a call of the native `each`/`map` (`Node.guard`/`Proto.guard`, set by `call` in lang.zig, checked again when the lambda is created: the name must still be global and the same native): it only lives while the loop runs, so it captures nothing, and a `for` inside a loop body no longer costs its enclosing scope its recycling (this works only because a real closure marks the whole chain). This removes most allocation (about two thirds of all objects in microgpt).
- To stress the collector, `make test-gc` runs both suites with the initial `limit` and the floor assigned by `collect` in gc.zig at 2048 bytes.

## Language semantics

- **Macros**: any root-scope function named `macro/*` is applied to every AST node before it is compiled (raw node in, node out), once per node (see the compiler in lang.zig); defining or changing a `macro/*` bumps `scope.epoch` so nodes compile again. Numbers, booleans and nil skip macros. `in_macro` prevents re-entrant expansion.
- Symbols and strings are the same type; string literals stay distinct in the AST (`.lit`) and evaluate to strings.
- `&&`/`||` are short-circuit special forms in head position (Code/Kind `&&`/`||`); passed as values they are the plain primitives.
- `0` and `""` are falsy, `'()` is truthy; `eq?` treats an empty list as `nil`.
- `(lambda (a & rest) ...)`: the compiler drops `&` and sets `Proto.rest`; `scope.bind` gives the last parameter the extra arguments as a list. The parser reads `'` `` ` `` `~` `~@` as `quote`, `quasiquote`, `unquote`, `unquote-splicing` forms (prefix markers on the `open` stack, negative entries); `quasiquote` itself is a Lisp macro in the stdlib (`quasi`).
- `defmacro` (stdlib, written without backquote): `(defmacro name (a & rest) body...)` defines `macro/name`, which checks the head, binds the parameters to the form's parts and returns the body's value. Code that runs inside a macro is never macro-expanded (`in_macro`), so macro bodies and the helper functions they call can't use macros; `defmacro` pre-rewrites backquote in its body (`quasi-walk`), the one exception. A template can't contain another one.
- Stdlib macros: `defn` (several body expressions become a `begin`), `fn` (a lambda with several body expressions), `->` (thread-first), `chain` (composes blocks; each block expression is evaluated once, as an argument of a wrapper lambda), `for` (expands to `each`, a `map` that keeps no result list) and `for/list` (expands to `map`; a pattern variable over `(zip xs ys)` becomes a multi-list `map`), `defrec`, `deftest`. `examples/autograd.lisp` adds `val` (infix arithmetic on values, Python's precedence) and `slots` (`(data v)` is `(at v 0)`).
- `map` takes several lists, `(map l1 ... ln f)`, and stops at the shortest; `range`, `zip` and `apply` are natives (a Lisp `zip`/`range` built with `cons`/`rest` is quadratic, since both copy); `flatten` is `(apply concat lst)` and `filter` builds on it.
- `defrec` rewrites self-calls into thunks and wraps the function with the native `trampoline`.

## Tests

Add a case whenever behaviour changes.
- `spec/specs.lisp`: `deftest` + `assert` (the test name is a string, so it can have spaces, and by convention reads `area: what it checks`; a symbol works too; `deftest` rewrites each `(assert expr)` to carry the test name and the quoted expression, so a failure prints both; `equal?` is a deep comparison), ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, 100k+ deep recursion through `map`/`reduce`/`partial`/`try` callbacks, errors unwinding them).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
