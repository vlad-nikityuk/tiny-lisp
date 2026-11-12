# Tiny Lisp Interpreter

A minimalistic Lisp interpreter in C, featuring macro support, tail-call optimization, and a small standard library.

Created *just for fun* and educational purposes. The interpreter (`src/lisp.c`) is at most 100 lines, based on [norvig.com/lispy.html](http://norvig.com/lispy.html).

## Layout

- `src/lisp.c`: parser, evaluator, primitives, REPL
- `src/gc.c`: memory management (reference counts + per-call regions)
- `src/stdlib_native.c` + `src/stdlib.lisp`: standard library (native part, Lisp part)
- `spec/specs.lisp`: Lisp test suite; `spec/repl.py`: REPL-driven tests

## Usage

```bash
make                         # build ./tiny-lisp
./tiny-lisp                  # REPL
./tiny-lisp -f file.lisp     # run a file
./tiny-lisp --debug          # set *DEBUG* to #t
make test                    # run all tests
```

## Language Features

### Basic Syntax

**Arithmetic & Logic:**
```lisp
#> (+ 1 2 3)
6
#> (- 10 3)
7
#> (eq? 1 1)
#t
#> (if #t "yes" "no")
"yes"
```

**Lists & Data Structures:**
```lisp
#> (list 1 2 3)
(1 2 3)
#> (cons 0 '(1 2 3))
(0 1 2 3)
#> (car '(a b c))
a
#> (cdr '(a b c))
(b c)
```

**Variables & Functions:**
```lisp
#> (define x 42)
42
#> (define square (lambda (n) (* n n)))
#> (square 5)
25
```

### Advanced Features

#### Macros
Define compile-time transformations with powerful macro system:

```lisp
;; Function definition shorthand
(defn factorial (n) (if (<= n 1) 1 (* n (factorial (- n 1)))))

;; Custom control structures
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (list "not" (second ast)) (third ast))
      ast)))

(unless #f (print "This will execute"))
```

#### Tail-Call Optimization with Trampoline
Efficient recursive functions that don't blow the stack:

```lisp
;; Define tail-recursive functions
(defrec factorial-tr (n acc)
  (if (<= n 1)
    acc
    (factorial-tr (- n 1) (* n acc))))

;; Works for moderate recursion depth
(factorial-tr 100 1)  ; => 9.332621544394418e+157
```

#### Church Encoding & Functional Data Structures
```lisp
;; Church-encoded linked lists
(define lst (c/cons 1 (c/cons 2 nil)))
(c/head lst)  ; => 1
(c/tail lst)  ; => (c/cons 2 nil)
```

#### Testing Framework
```lisp
;; Define unit tests
(deftest basic-math
  (assert (eq? (+ 2 3) 5)))

(deftest list-operations
  (assert (equal? (cons 1 '(2 3)) '(1 2 3))))

;; Run all tests
(run-tests)
```

#### Higher-Order Functions
```lisp
;; Map, reduce, filter operations
(map '(1 2 3 4) (lambda (x) (* x x)))  ; => (1 4 9 16)
(reduce '(1 2 3 4) + 0)                ; => 10
(partial + '(1 2))                     ; => partially applied function
```

#### Pattern Matching & Destructuring
```lisp
;; List comprehension-style operations
(zip '(1 2 3) '(a b c))  ; => ((1 a) (2 b) (3 c))
(concat '(1 2) '(3 4))   ; => (1 2 3 4)
```

## Architecture

- **Parser**: iterative S-expression parser
- **Evaluator**: explicit-stack machine. Pending work (`if`, `begin`, `define`, argument evaluation) lives in heap frames and tail calls replace the current state, so recursion depth is limited by memory, not the C stack
- **Macros**: every `macro/*` function in the root scope rewrites each AST node before evaluation
- **Memory**: heap reference counts plus per-call allocation regions, no tracing GC
- **Stdlib**: see `src/stdlib.lisp` for `defn`, `defrec`, `deftest`, list utilities and Church lists
