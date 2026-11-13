;; The Lisp part of the standard library, loaded after the native part (natives.zig).
(define pi 3.141592653589793)
(define first car)
(define rest cdr)

;; Macros. (defmacro name (a b & rest) body...) is understood by the expander itself (src/lang/expand.zig), not defined here: when
;; a top-level form containing one is expanded, the macro's function (lambda (a b & rest) body...) is made right away and kept
;; under name. Wherever (name x y z ...) appears in a form read later, it is replaced by the function's value for x, y, z, ...
;; (until its head is no macro), so (defmacro twice (x) (list 'begin x x)) makes (twice (print 1)) mean (begin (print 1) (print 1)).
;;
;; Bootstrapping: a macro body may use macros, but only those defined before it. Backquote is the macro `quasiquote`, so the
;; helpers it needs (begin-of, quasi-item, quasi) are plain functions written with define and lambda, and the quasiquote macro
;; comes right after them. Everything below may use backquote, and the macros defined above it (defn, fn, for, ...).

;; several expressions in a row become one (begin ...); a single expression stays as it is
(define begin-of
  (lambda (exprs)
    (if (eq? (len exprs) 1) (first exprs) (cons "begin" exprs))))

;; `x builds the list x with holes: ~e is replaced by the value of e, ~@e by the items of the list e (a template inside a
;; template is an error)
;; `(define ~name (lambda ~args ~@body)) -> (concat (list 'define) (list name) (list (concat ...)))
(define quasi-item
  (lambda (item)
    (if (eq? (first item) "unquote-splicing") (first (rest item)) (list "list" (quasi item)))))

(define quasi
  (lambda (x)
    (if (list? x)
      (if (eq? (first x) "unquote") (first (rest x))
        (if (eq? (first x) "quasiquote") (error "TinyLisp: nested quasiquote is not supported")
          (cons "concat" (map x quasi-item))))
      (list "quote" x))))

(defmacro quasiquote (x) (quasi x))

;; shorthand for defining functions; the body may be several expressions
;; (defn name args expr...) -> (define name (lambda args (begin expr...)))
;; (defn _add (a b) (+ a b))
(defmacro defn (name args & body)
  `(define ~name (lambda ~args ~(begin-of body))))

;; a lambda whose body may be several expressions
;; (fn (args) expr...) -> (lambda (args) (begin expr...))
(defmacro fn (args & body)
  `(lambda ~args ~(begin-of body)))

(defn second (l) (first (rest l)))
(defn third (l) (first (rest (rest l))))

;; (for/bindings (a b) 0) -> ((define a (at for/item 0)) (define b (at for/item 1)))
(defn for/bindings (names i)
  (if (eq? (len names) 0) '()
    (cons (list "define" (first names) (list "at" "for/item" i)) (for/bindings (rest names) (+ i 1)))))

;; the lambda of a loop; a variable written as a pattern (a b) takes each item (a list) apart
(defn for/lambda (var body)
  (if (list? var)
    (list "lambda" (list "for/item") (begin-of (concat (for/bindings var 0) body)))
    (list "lambda" (list var) (begin-of body))))

;; the loop as a map call; over (zip xs ys) it walks the lists side by side, without building the pairs
(defn for/map (var source body head)
  (if (&& (list? var) (eq? (first source) "zip"))
    (concat (list head) (rest source) (list (list "lambda" var (begin-of body))))
    (list head source (for/lambda var body))))

;; loops over a list, like Python's for and list comprehensions
;; (for (x lst) body...)      -> (each lst (lambda (x) body...))   ; each is map without the result list; it returns nil
;; (for/list (x lst) body...) -> (map lst (lambda (x) body...))
;; (for/list ((a b) (zip xs ys)) (* a b)) -> (map xs ys (lambda (a b) (* a b)))
(defmacro for (spec & body)
  (for/map (first spec) (second spec) body "each"))

(defmacro for/list (spec & body)
  (for/map (first spec) (second spec) body "map"))

;; (-> x step...) threads a value through the steps, like a stream pipeline: a name f is (f x), a form (f a) is (f x a)
;; (-> probs (at 3) vlog vneg) -> (vneg (vlog (at probs 3)))
(defn thread-step (x step)
  (if (list? step) (cons (first step) (cons x (rest step))) (list step x)))

(defmacro -> (x & steps)
  (reduce steps thread-step x))

;; (chain block...) is the block that feeds its input through the blocks in turn, like Keras's Sequential. A block is any
;; expression whose value is a function of one argument; each is evaluated once, when the chain is built.
;; (chain rmsnorm (Linear w) relu) -> ((lambda (b0 b1 b2) (lambda (x) (b2 (b1 (b0 x))))) rmsnorm (Linear w) relu)
(defmacro chain (& blocks)
  (define names (map (range (len blocks)) (lambda (i) (+ "chain/b" i))))
  `((lambda ~names (lambda (chain/x) ~(reduce names (lambda (acc name) (list name acc)) "chain/x")))
    ~@blocks))

;; defrec
;; ----------------------------------------------------------------
;; (defrec name args body): self calls in the body become thunks, and the trampoline runs them in a loop
(defn patch-rec-trampoline (ast name)
  (if (list? ast)
    (if (eq? name (first ast))
      (list "lambda" '() ast) ; (a 1 2 3) -> (lambda () (a 1 2 3))
      (map ast (lambda (x) (patch-rec-trampoline x name))))
    ast))

(defmacro defrec (name args expr)
  `(define ~name (trampoline (lambda ~args ~(patch-rec-trampoline expr name)))))

;; utilities
;; ----------------------------------------------------------------
(defn trace (x) (print x) x)
(defn pass () 0)
(defn color (code x) (+ ESC "[" code "m" x ESC "[39m"))
(defn red (x) (color 31 x))
(defn green (x) (color 32 x))
(define newline "
") ; strings have no escapes, so a newline is written out

;; Park-Miller random numbers in [0, 1); (set! rng-state n) reseeds.
(define rng-state 20240607)
(defn rand ()
  (set! rng-state (- (* 16807 rng-state) (* 2147483647 (floor (/ (* 16807 rng-state) 2147483647)))))
  (/ rng-state 2147483647))

;; lists
;; ----------------------------------------------------------------
(defn empty? (lst) (eq? (len lst) 0))

(defn iterate (lst f) (map lst f) nil)

;; (r/reduce lst f memo) folds from the right; it recurses on (rest lst), so it is quadratic: prefer reduce
(defn r/reduce (lst f memo)
  (if (empty? lst) memo
    (f (first lst) (r/reduce (rest lst) f memo))))

;; one level: (flatten '((1 2) (3))) is (1 2 3); a single copy, however many lists
(defn flatten (lst) (apply concat lst))

;; the items for which (keep? item) is true, in order
(defn filter (lst keep?)
  (flatten (for/list (x lst) (if (keep? x) (list x) '()))))

;; unit tests
;; ----------------------------------------------------------------
;; (assert expr message...) fails with an error unless expr is true. Inside a deftest the macro rewrites every assert to
;; (assert expr 'test-name 'expr message...), so the error says which test and which expression failed.
(defn assert (expr & info)
  (if (eq? #f expr)
    (error (if (eq? (len info) 0) "assertion-failed"
             (+ "assertion failed in " (first info) ": " (second info)
                (reduce (rest (rest info)) (lambda (text message) (+ text " " message)) ""))))
    #t))

(define *TESTS* '())

;; element-wise, at any depth; lists of different lengths are never equal
(defn equal? (a b)
  (if (&& (list? a) (list? b))
    (&& (eq? (len a) (len b))
        (reduce (zip a b) (lambda (ok pair) (&& ok (equal? (first pair) (second pair)))) #t))
    (eq? a b)))

;; (patch-asserts '(assert (eq? 1 x)) 'my-test) -> (assert (eq? 1 x) (quote my-test) (quote (eq? 1 x)))
;; Quoted data is left alone. Runs inside the deftest macro, so it uses only functions and special forms.
(defn patch-asserts (x test-name)
  (if (list? x)
    (if (eq? (first x) "quote") x
      (if (eq? (first x) "assert")
        (concat (list "assert" (second x) (list "quote" test-name) (list "quote" (second x))) (rest (rest x)))
        (map x (lambda (y) (patch-asserts y test-name)))))
    x))

(defmacro xdeftest (& body) '(pass))

;; (deftest name expr...) registers a test; the name is a symbol or a string, so it can have spaces:
;; (deftest "eq? says a number is itself" (assert (eq? 0 0)))
(defmacro deftest (name & body)
  (define label (first (split name newline))) ; as a plain string, which prints without quotes
  `(set! *TESTS* (concat *TESTS* (list (list (quote ~label) (lambda () ~(patch-asserts (begin-of body) label)))))))

;; runs every test: ✔ for a pass, 𝕏 and the message for a failure; the run fails (non-zero exit) if any test did
(defn run-tests ()
  (define failures 0)
  (iterate *TESTS*
    (fn (test)
      (try
        (fn ()
          ((second test))
          (print (green "✔") (first test)))
        (fn (message)
          (set! failures (+ failures 1))
          (print (red "𝕏") (first test))
          (print "   " message)))))
  (if (> failures 0) (error (+ failures " of " (len *TESTS*) " tests failed"))))
