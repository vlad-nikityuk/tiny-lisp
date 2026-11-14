# TinyLisp documentation

This folder documents the language and the implementation. It is written for people reading the source to learn how a small Lisp is built. Claims are checked against `src/`; runnable examples use `./tinylisp` from the repository root.

## Contents

| Document | What it covers |
|---|---|
| [language.md](language.md) | Syntax, values, special forms, truthiness, function-body scope rules, macros, quasiquote, stdlib forms, errors |
| [architecture.md](architecture.md) | Pipeline (parser → expand → compile → bytecode → exec), `src/` layout, import direction |
| [vm.md](vm.md) | Bytecode opcodes, fixed slots, inlining, VM loops, epoch invalidation, tail calls |
| [memory.md](memory.md) | NaN-boxed `V`, mark-sweep GC, roots, scope recycling |
| [continuations.md](continuations.md) | `call/cc` capture and invoke, limits |
| [ffi.md](ffi.md) | Register-split C calls, callbacks, `define-library`, libuv and `node.lisp`, limits |
| [decisions.md](decisions.md) | Design decision log (context, decision, rejected alternatives) |
| [limitations.md](limitations.md) | Known limits and backlog items |

## For contributors and agents

[`CLAUDE.md`](../CLAUDE.md) (also [`AGENTS.md`](../AGENTS.md)) is the dense, code-accurate map used by tooling and `spec/repo_rules.py`. These docs explain the same system in longer form for humans. When the two disagree, the code wins—file a doc fix.

## Build and verify

```bash
make                         # ./tinylisp
make check-all               # tests + lint (includes repo_rules.py)
./tinylisp -f file.lisp      # run a file (loads stdlib.lisp at start)
```