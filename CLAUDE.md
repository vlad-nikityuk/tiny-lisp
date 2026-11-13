# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## This is an educational project

Readability and understandability come first: someone should be able to read the source to learn how a small Lisp is built. Prefer the simple, explicit design over the clever one, name things for what they mean, keep comments for the why, keep modules small and each with one job, and delete code that does not pay for itself. Both execution tiers stay: the tree evaluator (`src/lang/`) is the reference semantics and the bytecode tier (`src/vm/`: `compiler.zig` compiles, `exec.zig` runs) is the fast path; simplify around them, not by removing either. A speed-up or a simplification is only kept if the tests pass and `make bench` does not get slower (see Tests).

## Commands

```bash
make                       # build ./tinylisp (Zig 0.17, ReleaseSafe: bounds/overflow checks, links libc)
make test                  # spec/repl.py + spec/specs.lisp
make test-tree             # the same tests with the bytecode tier off: both tiers must agree
make test-gc               # the same tests with the collection threshold at 2 KB (at least 2 KB allocated between collections, then half the live size, instead of 2 MB): stresses the collector's roots
make bench                 # bench/run.py: 18 programs in Python and tinylisp, same output checked, times compared (ARGS="-n 1 nbody")
make fast                  # ReleaseFast build without the checks (a previously measured ~4% faster): ./tinylisp-fast
./tinylisp [-f file.lisp] [--debug]
zig fmt --check src/       # every Zig source is zig fmt clean
```

## Architecture

`src/` is one entry point and four units; each file has one job:

```
src/repl.zig              the entry point: CLI and REPL, sets up the root scope (primitives, natives, stdlib.lisp)
src/runtime/              what both tiers and the natives share
    value.zig             V (NaN-boxed), the objects it points to (Lst, Fn, Lam), constructors and tests, the printer, the error value (errv, fail)
    gc.zig                the memory manager: allocation, mark-sweep, the roots, pinned values
    scope.zig             Env, the global table, epoch/shape, lookup and assignment, closures, scope recycling
    node.zig              compiled-code data both tiers use: Node, Code, Prim, Ref, Def, Proto, Guard, Sym
    machine.zig           Frame, Machine, Go, the ks/vs stacks, natives that call back into Lisp (start/step/finish/callback/tail), try/recover, the trampoline
    primitives.zig        + - car cons ...: `prim` specialised per Op, `numeric`, and `fast`/`fast1`, the in-place forms both tiers use
src/lang/                 the language: the reference semantics
    parser.zig            text -> AST (lists of values), iteratively
    expand.zig            macros: runs them over a whole top-level form before it is compiled or run, and carries out defmacro
    compile.zig           (expanded) AST -> nodes, lazily: intern, form, call recognition (force), the compiler stamp (current)
    eval.zig              the explicit-stack evaluator (eval/exec/run): runs nodes, and hands compiled functions to vm/
src/vm/                   the second tier, the fast path for function bodies
    bytecode.zig          the format: Opcode (each instruction documented), Ins, Bytecode
    scan.zig              which names of a function get fixed slots, and whether its body can be compiled at all
    compiler.zig          nodes -> bytecode (gen, inlining, loops), `ready`, the `enabled` switch of `make test-tree`
    exec.zig              the executor
src/lib/                  the standard library
    natives.zig           map each reduce apply range zip print partial concat, the file natives read-file write-file split, load and eval
    source.zig            a file's text, and running a file form by form (for the REPL's -f and the stdlib)
    stdlib.lisp           the Lisp part, loaded at start (path relative to the repo root)
```

**Dependency direction**: `runtime/` <- `lang/parser`, `lang/compile` <- `vm/` <- `lang/eval` <- `lang/expand` <- `lib/` <- `repl.zig` (an arrow reads "is used by"); a file imports the specific module it uses, there are no forwarding files. The exceptions are few, and these are all of them:
- `runtime/` -> `vm/bytecode.zig`: `Proto`, `Frame` and `Go` point to a `Bytecode` and `scope.bind` reads the slot names from it. `bytecode.zig` is pure data (it imports `runtime/` only), so this is a cycle between two data files, not between behaviours.
- Inside `runtime/`: `gc.zig` and the object owners (`value`, `scope`, `node`, `machine`) refer to each other, because the collector allocates their objects and traces their roots; `value.zig` names the other parts' types only as pointers.
- `lang/eval` -> `lang/compile` (the evaluator compiles nodes on demand, `compile.force`), and `lang/expand` -> `lang/eval` (a macro is a Lisp function: `eval.exec` runs it, the only nested machine); `lang/eval` never calls the expander.
- `lang/eval` -> `vm/` (`compiler.ready`, `exec.exec`: it hands compiled functions over) while `vm/` -> `lang/compile` (`force`, `current`: a body is forced and its stamp checked). `vm/` never imports `lang/eval`: the executor runs on the machine's stacks and returns to the evaluator's loop.
- `lib/natives.zig` -> `lang/expand`, `lang/compile`, `lang/parser` (`load` and `eval` expand a form and return it as `.eval` to the machine, in the caller's scope; they do not run it themselves).

Keep names meaningful and the total source small; keep the evaluator's control flow visible in `eval.run` and `exec.exec` rather than hidden behind helpers. All Zig sources are `zig fmt` clean. Errors are Zig error unions (`error.Lisp`); the raised Lisp value is in `value.errv`.

**The expander** (`lang/expand.zig`) runs before anything is compiled. A program is processed one top-level form at a time: read (`parser.parse`/`parseNext`), `expand.form` (every macro call in the form, the bodies of its lambdas included, is replaced by what the macro returns, until the head is no macro; an iterative walk with an explicit stack, rebuilding only the lists that changed, everything it holds pinned or on `vs` because macros run Lisp and the collector may run), then run. `expand.run` does the three steps for the REPL, `source.runFile` for `-f` and the stdlib, and the natives `load` (form by form, state in its native frame) and `eval` (one form, its own top level) do it inside the machine. So a macro defined by one form is in effect for the next, a macro body may call functions defined by earlier forms, and redefining a macro does not touch code that was expanded already. `defmacro` is understood here, not in the stdlib: `(defmacro name (params) body...)` at top level (directly, or inside a top-level `begin` at any depth) expands and runs `(lambda (params) (begin body...))` at once and keeps the function in `scope.macros` (a table keyed by name, marked by the collector); the macro is called with the parts of the form. A special form name, or a defmacro anywhere but top level, is an error (raised while the enclosing top-level form is expanded, so none of it runs).

**The tree compiler** (`lang/compile.zig`) turns the expanded AST into typed nodes (`node.Node`/`Code`: constant, variable, if, begin, &&/||, define/set!, lambda, call, prim) lazily, the first time a node is evaluated (no macro runs there); symbols are interned (`Sym`; scope keys compare by address; a name no scope has ever bound (`Sym.local`) is looked up in the global table directly, with the slot cached in the node). Nodes, their arrays and symbols are permanent (`gc.perm`); the AST they came from (and macro expansions) is pinned for good with `gc.pin`, so frames and closures (`Lam.proto`) point at nodes freely.

**Primitive calls in place**: a one- or two-operand call whose head is a global bound to `+ - * / mod < > <= >= eq? at` (two operands) or `not abs floor sqrt exp log cos` (one) compiles to `Code.prim` (`call` in compile.zig). `eval.atom` computes it with `primitives.fast` when its operands are constants, variables or such calls up to 3 levels deep (no frame, no call); it falls back to the plain call `Prim.c` if the name was rebound (`sym.local` or the global slot changed), an operand cannot be evaluated within the bounded in-place descent (`Prim.slow`) or the operands are not plain numbers/list+index. `atom`'s slow part (`inplace`) must stay out of line: inlining it into `run` made everything slower.

**Tier 2** (`src/vm/`: `scan.zig` and `compiler.zig` compile, `exec.zig` runs): the first call of a function (a `Proto`) compiles its whole body to a stack bytecode (`bytecode.Bytecode`/`Ins`/`Opcode`, each instruction documented there) and its parameters and defines get **fixed slots** in the call's scope (`scope.bind` creates them all up front, defines as nil). `eval.run` has a `.vm` step (`exec.exec` runs instructions until it needs the machine: a call, or a return) and a `vm` frame kind that resumes the code at the instruction after a call. Tail calls are `.apply` as before; a function calling itself in tail position in a scope no closure holds (`Env.captured`) reuses that scope. Locals are `local`/`setlocal` slot accesses; other names go through `outer`/`setouter`, which remember `(hops, index)` after the first lookup (the scopes passed must be tier-2 scopes, so their layout is fixed) and only check the key. Primitive calls (`+ - * < > <= >= eq? at` and the rest of `Prim`) are instructions, fused with local/constant operands where possible; `vset!`, `each` and `map` have their own instructions. A call of a small global function without closures (`genInline`) is compiled into the caller, with slots of its own and its free names read as globals (`global`/`setglobal`); replacing such a function bumps `epoch` (`Proto.inlined`, `scope.replace`). `(each list (lambda (x) ...))` (so `for`) and `(map ...)` (so `for/list`) with one list are a **loop run by the bytecode**: a `loop` frame keeps the list position on the value stack and the last iteration's scope (`Frame.iter_env`, marked by the collector), which the next iteration reuses unless a closure captured it; the loop body is its own bytecode and returns to the loop with the instruction `ret`. Compiled code is valid for a compiler stamp (`compile.current()`, from `scope.epoch`); rebinding a primitive or `each` (any `Sym.inlined`) bumps `epoch`, which compiles everything again (from the same expanded AST).
- What stays with the tree evaluator (the reference semantics): a body the compiler rejects (nested too deep; a `define` of a name that was used earlier in the body, or used after the branch it was defined in; an error while compiling a node).
- Differences from the tree evaluator that are on purpose: a primitive rebound while a function that inlines it is running is seen only by calls started afterwards.
- Known intentional difference, a call of an undefined function: the tree tier looks the function up first and fails before evaluating the arguments; the bytecode tier pushes the arguments (evaluating them, with their side effects) and fails only at the call. It is how the baseline behaves, not a regression, and either way the same error is raised.
- Tests: `spec/specs.lisp` has "tier 2: ..." cases; `make test-tree` runs both suites with the tier off (`enabled` in vm/compiler.zig) to check they agree.

**Evaluator**: explicit-stack machine, no native recursion per Lisp call, nesting level or callback, so there is no recursion limit other than memory. Pending work is a frame on the global `ks` stack (`if` waiting for its condition, `begin` mid-sequence, `define`/`set!` waiting for the value, `apply` collecting the function and arguments on the operand stack `vs`, `native`). The machine state is a `Go`: evaluate a node, hand a value to the innermost frame, or apply the function at `vs[b]` to the arguments after it. Tail positions (if branches, last of begin, lambda bodies) replace the current state instead of pushing a frame.
- **Natives that call back into Lisp** (`map`, `reduce`, `try`, `partial`, the trampoline and its thunks) are `Native.step` functions and run as `native` frames: their arguments stay on `vs` after the native (`vs[k.base]`), their state goes after them or in `k.i`. A step is invoked with `null` first, then with each callback's value, and returns the next `Go` via the helpers in `runtime/machine.zig`: `finish` (pop, hand on a value), `callback` (call a function, its value comes back to the frame) or `tail` (replace the frame by a call, e.g. `partial`). Plain natives (`Native.plain`) just compute a value.
- **Errors** (`error.Lisp`, value in `value.errv`) are caught by `exec`: `machine.recover` drops the frames above the innermost `try` frame of this run and resumes it with the error value, which tail-calls the handler. Without one, the run truncates `ks`/`vs` to its base (`errdefer`) and the error propagates. The trampoline's "active" flag (`s.i` = index + 1 of its run frame) is validated against `ks`, so a run frame dropped by an error doesn't leave it stuck.
- **Macro expansion** (`expand.zig`) is the only nested machine (`call` → `exec`); macro bodies are expanded too, so macros may call macros, nested to any depth, one nested machine per macro call being run.
- Parser, printer and freeing are iterative too.

**Values**: `V` is an 8-byte NaN-boxed `enum(u64)` (`V` in `runtime/value.zig`): a number is its own double (NaN is canonicalised by `V.num`), everything else is a tagged payload in the quiet-NaN space (`nil`, bool, symbol/string, string literal, list, native function, closure). Build with `V.num/boolean/string/literal/listOf/fnOf/lamOf`, read with `tag()`/`is(tag)`/`asNum/asBool/asStr/asList/asFn/asLam`; compare with `==` only for identity or `V.nil` (use `.is(.n)` and `asNum` for numbers). A list is a length followed by its items (`Lst.items()`).

**Memory (`src/runtime/gc.zig`)**: stop-the-world mark-sweep on libc malloc. Every managed object (`alloc`/`new(T, extra, kind, init)`, not zeroed: constructors set every byte they use) has a one-word header (next object | kind | mark) and sits on one list; `perm` objects (parser symbols/literals, compiled nodes, root keys, root scope) are never collected. Nothing is counted: the evaluator calls `gc.collect()` at `.eval` and `.vm`, and the VM at self-tail-call backedges and loop iterations once `gc.due()` says about half as much as is live has been allocated (at least 2 MB), with every live managed value reachable from a root; natives may allocate freely. Roots (`gc.markRoots`): the `ks`/`vs` stacks (frames' scopes), every running machine's scope (`machine.machines`), the global table, `gc.pin`ned values (the AST that compiled nodes refer to) and `errv`. Marking and sweeping use worklists, never recursion; cycles are collected; allocation failure exits with `TinyLisp: out of memory`.
- Anything new that holds a value outside those roots (a Zig-side global, a cache) must be marked in `gc.markRoots`.
- At collection, publish the VM stack pointer in `vs.items.len` and keep the active scope in the registered machine. A Zig local may survive collection only if its managed object is also reachable from a root; never rely on a local alone across an `.eval` step.
- **Scope recycling**: the scope of a call (`Env`, `scope.bind`) is handed back to a free list (`scope.release`) when the call ends (a tail call, or a return into a frame of another scope) if it is still `Env.recyclable` (`scope.lambda` clears that when a closure captures it). Recycling assumes only frames, `m.e` and closures hold a scope; the collector forgets the free list. A closure (`scope.lambda`) marks its scope and every enclosing one as `captured` and no longer recyclable. The exception is the lambda that is the last operand of a call of the native `each`/`map` (`Node.guard`/`Proto.guard`, set by `call` in compile.zig, checked again when the lambda is created: the name must still be global and the same native): it only lives while the loop runs, so it captures nothing, and a `for` inside a loop body no longer costs its enclosing scope its recycling (this works only because a real closure marks the whole chain). This removes most allocation (about two thirds of all objects in microgpt).
- To stress the collector, `make test-gc` runs both suites with the initial `limit` and the floor assigned by `collect` in gc.zig at 2048 bytes (a minimum threshold of 2 KB allocated between collections; afterwards the limit follows half the live size as usual).

## Language semantics

- **Macros**: `(defmacro name (a & rest) body...)` (see the expander above) makes a function of the form's parts, `(name x y ...)` is replaced by its value, again and again until the head is no macro. Top-level only (a defmacro anywhere else, or named like a special form, is an error). Each top-level form is expanded whole before it runs (REPL line; file form by form; `eval`'s argument); macros defined by earlier forms are in effect, a macro's body and the functions it calls may use macros defined before it, and redefining a macro changes only the forms expanded afterwards. `quote`d data and a lambda's parameter list are not expanded. Numbers, booleans and nil are never macro calls.
- Symbols and strings are the same type; string literals stay distinct in the AST (`.lit`) and evaluate to strings.
- `&&`/`||` are short-circuit special forms in head position (Code/Kind `&&`/`||`); passed as values they are the plain primitives.
- `0` and `""` are falsy, `'()` is truthy; `eq?` treats an empty list as `nil`.
- `(lambda (a & rest) ...)`: the compiler drops `&` and sets `Proto.rest`; `scope.bind` gives the last parameter the extra arguments as a list. The parser reads `'` `` ` `` `~` `~@` as `quote`, `quasiquote`, `unquote`, `unquote-splicing` forms (prefix markers on the `open` stack, negative entries); `quasiquote` itself is a Lisp macro in the stdlib (`quasi`).
- **Bootstrapping** (top of `stdlib.lisp`): `quasiquote` is a macro (`quasi`, plain functions written with `define`/`lambda`, defined first); every macro after it may use backquote. A template inside a template raises `TinyLisp: nested quasiquote is not supported` (a template inside a `~` is fine).
- Stdlib macros: `defn` (several body expressions become a `begin`), `fn` (a lambda with several body expressions), `->` (thread-first), `chain` (composes blocks; each block expression is evaluated once, as an argument of a wrapper lambda), `for` (expands to `each`, a `map` that keeps no result list) and `for/list` (expands to `map`; a pattern variable over `(zip xs ys)` becomes a multi-list `map`), `defrec`, `deftest`. `examples/autograd.lisp` adds `val` (infix arithmetic on values, Python's precedence) and `slots` (`(data v)` is `(at v 0)`).
- `map` takes several lists, `(map l1 ... ln f)`, and stops at the shortest; `range`, `zip` and `apply` are natives (a Lisp `zip`/`range` built with `cons`/`rest` is quadratic, since both copy); `flatten` is `(apply concat lst)` and `filter` builds on it.
- `defrec` rewrites self-calls into thunks and wraps the function with the native `trampoline`.

## Tests

Add a case whenever behaviour changes.
- `spec/specs.lisp`: `deftest` + `assert` (the test name is a string, so it can have spaces, and by convention reads `area: what it checks`; a symbol works too; `deftest` rewrites each `(assert expr)` to carry the test name and the quoted expression, so a failure prints both; `equal?` is a deep comparison), ends with `(run-tests)`; a failing assert exits non-zero. Includes stack-safety tests (100k-deep recursion, deep data, 100k+ deep recursion through `map`/`reduce`/`partial`/`try` callbacks, errors unwinding them).
- `spec/repl.py <binary>`: drives the REPL and checks printed results (parsing, printing, errors, 100k-deep nesting).
