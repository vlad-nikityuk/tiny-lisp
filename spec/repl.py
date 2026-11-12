#!/usr/bin/env python3
"""Drives the REPL and checks each printed result.
Usage: python3 spec/repl.py <command...>   e.g. python3 spec/repl.py ./tiny-lisp"""
import re, subprocess, sys

ERROR = object()
CASES = [
    ("(()", ERROR),
    ("(define)", ERROR),
    ("(set!)", ERROR),
    ("())", ERROR),
    ("(begin (len '())\t (len '(1))  1)", "1"),
    ("'(1)", "(1)"),
    ("'hello-world", "hello-world"),
    ("'(hello-world)", "(hello-world)"),
    ("'(hello-world 1)", "(hello-world 1)"),
    ("(if #t " * 10000 + "42" + " 0)" * 10000, "42"),
    ("(begin " * 10000 + "42" + ")" * 10000, "42"),
    ("(eq? nil '())", "#t"),
    ("(cons 1 (cons 2 nil))", "(1 2)"),
    ("((lambda (x) x) 0)", "0"),
    ("(- 1 1)", "0"),
    ('(+ "foo " "bar")', "foo bar"),
    ("cons", "<function>"),
    ("(reduce '(1 2 3) (lambda (a x) (+ a x)) 0)", "6"),
    ("(undefined-fn 1)", ERROR),
    ("()", ERROR),
    ("(1 2)", ERROR),
    ("'((1 2) 3)", "((1 2) 3)"),
    ("''x", "(quote x)"),
    ("(quote (a 'b))", "(a (quote b))"),
    ('"a string"', "a string"),
    ("'(\"lit\" sym)", '("lit" sym)'),
    ("(+ 0.1 0.2)", "0.30000000000000004"),
    ("(/ 1 4)", "0.25"),
    ("(- 0 7)", "-7"),
    ("(* 100000 100000)", "10000000000"),
    ("(eq? 1 1)", "#t"),
    ("(list nil #t #f)", "(nil #t #f)"),
    ("(car '())", "nil"),
    ("((lambda (a b) (list a b)) 1)", "(1 nil)"),
    ("(define sq (lambda (x) (* x x)))", "<function>"),
    ("(sq 12)", "144"),
    ("(begin)", "nil"),
    ("(error 'custom)", ERROR),
    ("(try (lambda () (error 'custom)) (lambda (e) (list 'got e)))", "(got custom)"),
    ("(+ 1 2) ;; trailing comment", "3"),
    ("(+ 1 " * 100000 + "0" + ")" * 100000, "100000"),
    ("(len (list " + "'(1) " * 5000 + "))", "5000"),
    # natives calling back into Lisp are frames: no depth limit, errors unwind them
    ("(begin (define walk (lambda (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))) (walk 100000))", "100000"),
    ("(try (lambda () (map '(1) (lambda (x) (error 'deep)))) (lambda (e) (list 'got e)))", "(got deep)"),
    ("(map '(1 2) (lambda (x) (undefined-fn x)))", ERROR),
    ("(map '(1 2) (lambda (x) (* x 10)))", "(10 20)"),
    ("((partial map '((1 2))) (lambda (x) (+ x 1)))", "(2 3)"),
]

out = subprocess.run(sys.argv[1:], input="\n".join(src for src, _ in CASES) + "\n", capture_output=True, text=True).stdout
results = re.findall(r"\x1b\[(32|31)m(.*?)\x1b\[39m", out, re.S)
failed = 0
for (src, want), (color, got) in zip(CASES, results + [("", "<missing>")] * len(CASES)):
    ok = color == "31" if want is ERROR else (color == "32" and got == want)
    failed += not ok
    print(("PASS" if ok else "FAIL"), src[:60], "" if ok else f"-> got {got!r}, want {'error' if want is ERROR else want!r}")
print(f"{len(CASES) - failed}/{len(CASES)} passed")
sys.exit(1 if failed else 0)
