# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
pnpm install          # install dependencies
pnpm test             # run all tests (TypeScript unit tests + Lisp integration tests)
pnpm start            # start interactive REPL
pnpm start -f <file>  # run a .lisp file
pnpm start --debug    # REPL with debug mode (sets *DEBUG* #t in env)
pnpm build            # compile TypeScript to dist/
```

There is no separate lint command. TypeScript strict mode is enforced via `tsconfig.json`.

The test suite runs two suites in sequence: `node --test` on `spec/specs.ts` (TypeScript unit tests), then `tsx src/lisp.ts -f spec/specs.lisp` (Lisp integration tests that call `run-tests`).

## Architecture

The interpreter is split across two TypeScript files and two Lisp files:

**`src/lisp_lang.ts`** — the core language engine (~90 lines):
- `tokenize`: regex-based tokenizer; expands `'x` shorthand to `(quote x)` and strips `;;` comments
- `parse`: recursive descent parser; returns nested JS arrays as the AST (lists) or primitives (atoms)
- `createScope`: creates lexically-scoped environments as closures; `scope(name)` reads, `scope(name, val)` writes, `scope.root()` walks to the global env, `scope.find(name)` locates the defining scope for `set!`
- `_evalRec`: CPS (continuation-passing style) evaluator; handles `quote`, `if`, `define`, `set!`, `lambda`, `begin`, and function application; **macro expansion runs on every node before evaluation** by iterating all `macro/`-prefixed keys on the root scope
- `topLevel()`: builds the initial global environment with JS-backed primitives (`car`, `cdr`, `cons`, `len`, `list`, `eq?`, arithmetic operators via `new Function`, `js/eval`, `js/bind`, `trampoline`)

**`src/lisp.ts`** — the entry point / REPL:
- Loads `src/stdlib.lisp` automatically on every startup (before REPL or file execution)
- Wraps file contents in `(begin ...)` before evaluating
- Colors output: green for results, red for errors, yellow for debug notice

**`src/stdlib.lisp`** — standard library written in Lisp itself:
- Defines macros: `macro/defn` (function definition shorthand), `macro/defrec` (tail-recursive function via trampoline), `macro/deftest`/`macro/xdeftest` (test registration)
- List utilities: `map` (delegates to `Array.prototype.map`), `reduce` (delegates to `Array.prototype.reduce`), `l/reduce`/`r/reduce` (Lisp-native left/right reduce), `zip`, `concat`, `iterate`, `at`, `empty?`, `list?`
- Church-encoded linked lists: `c/cons`, `c/head`, `c/tail`
- Testing framework: `deftest` macro registers tests in `*TESTS*`; `run-tests` iterates and calls each
- JS interop helpers: `print` (`console.log`), `pi` (`Math.PI`), `red`/`green` (terminal colors from the `colors` global)

**`spec/specs.lisp`** — integration tests; ends with `(run-tests)` which executes everything registered via `deftest`

**`spec/specs.ts`** — TypeScript unit tests using `node:test`; tests the tokenizer/parser/evaluator directly against `topLevel()` (no stdlib loaded)

## Key design points

**Macros**: any function defined in the root scope with a `macro/` prefix is applied to every AST node before evaluation. Macros receive the raw AST node and return a (possibly transformed) node. The `inMacro` flag prevents re-entrant macro expansion.

**Trampoline / tail-call optimization**: `trampoline` is a JS-level wrapper in `topLevel`. `defrec` compiles a tail-recursive function by rewriting self-calls into `(lambda () (self-call ...))` (via `patch-rec-trampoline`), then wrapping the whole thing with `trampoline`. This avoids JS stack overflows for deep recursion.

**CPS evaluator limitation**: although the evaluator uses CPS internally, it runs on the JS call stack and is not actually stack-safe for deeply nested expressions — the trampoline only helps for explicit `defrec` functions, not general recursion.

**`js/eval` / `js/bind`**: direct escape hatches into JavaScript; `stdlib.lisp` uses them extensively to wrap native array methods and `console.log`.

**Numbers vs strings**: `atom()` in the parser calls `parseFloat`; anything that doesn't parse as a number stays as a string. String literals (double-quoted) are stored with their quotes and stripped only at evaluation time.

**Known issue** (see TODO in `lisp_lang.ts`): `+` is string-concatenating when used via the Lisp `reduce` because JS coerces types; `(reduce '(1 2 3) + 0)` returns `"0123"` not `6`.
