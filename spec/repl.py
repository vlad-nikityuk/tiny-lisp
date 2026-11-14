#!/usr/bin/env python3
"""Drives the REPL and checks each printed result.
Usage: python3 spec/repl.py <command...>   e.g. python3 spec/repl.py ./tinylisp"""
import os, re, subprocess, sys

ERROR = object()


class Error(str):
    """An error whose message is this text."""


CASES = [
    ("parse: unclosed paren is an error", "(()", ERROR),
    ("define: needs a name", "(define)", ERROR),
    ("set!: needs a name", "(set!)", ERROR),
    ("parse: extra closing paren is an error", "())", ERROR),
    ("parse: tabs and double spaces separate items", "(begin (len '())\t (len '(1))  1)", "1"),
    ("quote: a list", "'(1)", "(1)"),
    ("quote: a symbol with a dash", "'hello-world", "hello-world"),
    ("quote: a list holding a dashed symbol", "'(hello-world)", "(hello-world)"),
    ("quote: a dashed symbol next to a number", "'(hello-world 1)", "(hello-world 1)"),
    # (the parser, expander and printer have no nesting limit: deep data is fine. Code is compiled by recursion, so it has one.)
    ("parse: 10,000 nested ifs as data", "(len '" + "(if #t " * 10000 + "42" + " 0)" * 10000 + ")", "4"),
    ("parse: 10,000 nested begins as data", "(len '" + "(begin " * 10000 + "42" + ")" * 10000 + ")", "2"),
    ("compile: code nested 4,900 deep runs", "(if #t " * 4900 + "42" + " 0)" * 4900, "42"),
    ("compile: code nested 5,100 deep is refused", "(if #t " * 5100 + "42" + " 0)" * 5100, Error("TinyLisp: expression is nested too deeply to compile (limit 5000)")),
    ("compile: a function nested 4,900 deep runs", "((lambda () " + "(+ 1 " * 4900 + "0" + ")" * 4900 + "))", "4900"),
    ("compile: a function nested 5,100 deep is refused", "(define too-deep-f (lambda () " + "(+ 1 " * 5100 + "0" + ")" * 5100 + "))", Error("TinyLisp: expression is nested too deeply to compile (limit 5000)")),
    ("compile: the REPL goes on after a refused form", "(+ 1 2)", "3"),
    ("eq?: nil is the empty list", "(eq? nil '())", "#t"),
    ("cons: builds a list", "(cons 1 (cons 2 nil))", "(1 2)"),
    ("lambda: applied at once", "((lambda (x) x) 0)", "0"),
    ("arithmetic: subtraction gives 0", "(- 1 1)", "0"),
    ("strings: + joins", '(+ "foo " "bar")', "foo bar"),
    ("values: a primitive prints as <function>", "cons", "<function>"),
    ("reduce: sums a list", "(reduce '(1 2 3) (lambda (a x) (+ a x)) 0)", "6"),
    ("errors: an undefined function", "(undefined-fn 1)", ERROR),
    ("errors: the empty list can't be evaluated", "()", ERROR),
    ("errors: a number is not a function", "(1 2)", ERROR),
    ("quote: nested lists", "'((1 2) 3)", "((1 2) 3)"),
    ("quote: a quote of a quote", "''x", "(quote x)"),
    ("quote: ' inside a list", "(quote (a 'b))", "(a (quote b))"),
    ("parse: ` ~ and ~@ read as quasiquote forms", "'`(a ~b ~@c)", "(quasiquote (a (unquote b) (unquote-splicing c)))"),
    ("lambda: & collects the extra arguments", "((lambda (a & more) (list a more)) 1 2 3)", "(1 (2 3))"),
    ("lambda: & gives an empty list when there are none", "((lambda (a & more) more) 1)", "()"),
    ("lambda: & alone takes every argument", "((lambda (& all) (len all)))", "0"),
    ("define: returns the value", "(define x 5)", "5"),
    ("quasiquote: inserts and splices", "`(a ~x ~@(list 1 2) b)", "(a 5 1 2 b)"),
    ("quasiquote: a template inside a template is an error", "`(a `(b ~x))", ERROR),
    ("defmacro: its value is the name", "(defmacro repl-pair (a) (list 'list a a))", "repl-pair"),
    ("defmacro: in effect for the next line", "(repl-pair 3)", "(3 3)"),
    ("defmacro: redefined for the next line", "(begin (defmacro repl-pair (a) (list 'list a a a)) (list 1))", "(1)"),
    ("defmacro: the new one applies from then on", "(repl-pair 3)", "(3 3 3)"),
    ("defmacro: in a top-level begin, for what follows in it", "(begin (defmacro repl-four () 4) (repl-four))", "4"),
    ("defmacro: inside a lambda is an error", "(lambda () (defmacro repl-bad () 1))", ERROR),
    ("defmacro: a special form cannot be a macro", "(defmacro if (a) a)", ERROR),
    ("strings: a literal prints without quotes", '"a string"', "a string"),
    ("strings: a literal inside quoted data keeps its quotes", "'(\"lit\" sym)", '("lit" sym)'),
    ("numbers: floats print their shortest form", "(+ 0.1 0.2)", "0.30000000000000004"),
    ("numbers: division gives fractions", "(/ 1 4)", "0.25"),
    ("numbers: a negative result", "(- 0 7)", "-7"),
    ("numbers: big products stay exact", "(* 100000 100000)", "10000000000"),
    ("eq?: equal numbers", "(eq? 1 1)", "#t"),
    ("values: nil and booleans print", "(list nil #t #f)", "(nil #t #f)"),
    ("car: of the empty list is nil", "(car '())", "nil"),
    ("lambda: a missing argument is nil", "((lambda (a b) (list a b)) 1)", "(1 nil)"),
    ("define: a function", "(define sq (lambda (x) (* x x)))", "<function>"),
    ("lambda: calling a defined function", "(sq 12)", "144"),
    ("begin: with nothing is nil", "(begin)", "nil"),
    ("errors: error raises", "(error 'custom)", ERROR),
    ("errors: try hands the error to the handler", "(try (lambda () (error 'custom)) (lambda (e) (list 'got e)))", "(got custom)"),
    ("parse: a trailing comment is ignored", "(+ 1 2) ;; trailing comment", "3"),
    ("parse: 100,000 nested calls as data", "(len '" + "(+ 1 " * 100000 + "0" + ")" * 100000 + ")", "3"),
    ("parse: a call with 5,000 arguments", "(len (list " + "'(1) " * 5000 + "))", "5000"),
    # natives calling back into Lisp are frames: no depth limit, errors unwind them
    ("stack: 100,000 deep recursion through map", "(begin (define walk (lambda (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))) (walk 100000))", "100000"),
    ("errors: an error inside a map callback is caught", "(try (lambda () (map '(1) (lambda (x) (error 'deep)))) (lambda (e) (list 'got e)))", "(got deep)"),
    ("errors: an undefined function inside a map callback", "(map '(1 2) (lambda (x) (undefined-fn x)))", ERROR),
    ("map: applies a function to each item", "(map '(1 2) (lambda (x) (* x 10)))", "(10 20)"),
    ("math: exp log sqrt cos floor", "(list (exp 0) (log 1) (sqrt 16) (cos 0) (floor -0.5))", "(1 0 4 1 -1)"),
    ("split: by a separator", '(split "a,b,c" ",")', "(a b c)"),
    ("split: into characters", '(split "abc" "")', "(a b c)"),
    ("files: reading a missing file is an error", '(read-file "/nonexistent/file")', ERROR),
    ("files: loading a missing file is an error", '(load "/nonexistent/file")', ERROR),
    ("partial: a partly applied map", "((partial map '((1 2))) (lambda (x) (+ x 1)))", "(2 3)"),
]
# The scoping rules of function bodies.
CASES += [
    ("body: a define in a branch that did not run", "(define body-f (lambda (flag) (begin (if flag (define v 2) 0) v)))", "<function>"),
    ("body: the branch ran", "(body-f #t)", "2"),
    ("body: reading the name before its define is an error", "(body-f #f)", Error("TinyLisp: v is used before it is defined")),
    ("body: set! of a name that exists nowhere is an error", "(set! nowhere-at-all 1)", Error("TinyLisp: set!: nowhere-at-all is not defined")),
    ("body: set! of a global is fine", "(begin (define body-g 1) (set! body-g 2))", "2"),
]

process = subprocess.run(sys.argv[1:], input="\n".join(src for _, src, _ in CASES) + "\n", capture_output=True, text=True)
results = re.findall(r"\x1b\[(32|31)m(.*?)\x1b\[39m", process.stdout, re.S)
failed = 0
if process.returncode:
    print(f"REPL exited with status {process.returncode}: {process.stderr.strip()}")
    failed += 1
if len(results) != len(CASES):
    print(f"Expected {len(CASES)} results, got {len(results)}")
    failed += 1
passed = 0
for (name, src, want), (color, got) in zip(CASES, results + [("", "<missing>")] * len(CASES)):
    ok = color == "31" and (want is ERROR or got == want) if want is ERROR or isinstance(want, Error) else (color == "32" and got == want)
    failed += not ok
    passed += ok
    print(("\x1b[32m✔\x1b[39m" if ok else "\x1b[31m𝕏\x1b[39m"), name, "" if ok else f"-> got {got!r}, want {'error' if want is ERROR else want!r}")
print(f"{passed}/{len(CASES)} passed")
sys.exit(1 if failed else 0)
