# Tiny Lisp Interpreter

A minimalistic Lisp interpreter implemented in TypeScript, featuring macro support, tail-call optimization, and a comprehensive standard library.

Created *just for fun* and educational purposes.

~100 lines of core TypeScript code, based on [norvig.com/lispy.html](http://norvig.com/lispy.html).

## Installation

```bash
pnpm install
```

## Usage

### Interactive REPL
Start the interactive REPL to experiment with Lisp expressions:

```bash
pnpm start
```

### Run Lisp Files
Execute Lisp files directly:

```bash
pnpm start -f your-file.lisp
```

### Debug Mode
Enable debug mode for detailed execution tracing:

```bash
pnpm start --debug
```

### Run Tests
```bash
pnpm test
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

#### JavaScript Interoperability
```lisp
;; Call JavaScript functions
(define alert (js/eval "console.log"))
(alert "Hello from Lisp!")

;; Access JavaScript objects
(define pi (js/eval "Math.PI"))
(define random (js/eval "Math.random"))
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

- **Parser**: Tokenizes and parses S-expressions
- **Evaluator**: Continuation-passing style evaluator with macro expansion
- **Environment**: Lexically scoped variable bindings
- **Stdlib**: Rich standard library with macros and utility functions
- **Trampoline**: Eliminates tail-call stack growth (Note: Limited by evaluator's own recursion depth due to CPS implementation)

## Examples

Check out `src/stdlib.lisp` for comprehensive examples of:
- Macro definitions (`defn`, `deftest`, `defrec`)
- Recursive algorithms with trampoline optimization
- List processing utilities
- Testing framework implementation
- JavaScript interop patterns

## License

ISC

