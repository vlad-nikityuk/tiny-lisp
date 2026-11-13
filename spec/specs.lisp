;; deftest
;; 1. unfolds to (define (lambda ... ))
;; 2. adds itself to *TESTS* test list
;; 3. Adds expr: and test: to assert call


;; eq? tests
(deftest eq?--zero-is-zero
  (assert (eq? 0 0)))

(deftest eq?--nil-is-nil
  (assert (eq? nil nil)))

(deftest eq?--empty-list-is-nil
  (assert (eq? nil '()) ))


;; empty?
(deftest empty?--true
  (define res (empty? '()))
  (assert (eq? #t res)))

(deftest empty?--false
  (define res (empty? '(1 2)))
  (assert (eq? #f res)))


;; list?
(deftest list?-empty
  (define res (list? '()))
  (assert (eq? #t res)))

(deftest list?-with-elements
  (define res (list? '(1 2 3)))
  (assert (eq? #t res)))

(deftest list?-non-list
  (define res (list? 1))
  (assert (eq? #f res)))

(deftest concat-arrays
  (define res (concat '(4 5 6) '(1 2 3)))
  (assert (equal? '(4 5 6 1 2 3) res)))

(deftest equality
  (assert (eq? #t #t)
  (assert (eq? 4 4))))

(deftest first-returns-head-of-list
  (define lst '(4 5 6))
  (define fst (first lst))
  (assert (eq? fst 4)))

(deftest begin-should-return-last-expr
  (assert (eq? 4 (begin 1 2 3 4))))

(deftest assert-fails-on-false-expr
  (if
    (eq?
      (try
        (lambda () (begin (assert #f) #f))
        (lambda (e) #t))
      #t)
    (pass)
    (error 'oh-dear)))

(deftest at-returns-by-idx
  (define lst '(4 5 6))
  (assert (eq? (at lst 0) 4))
  (assert (eq? (at lst 1) 5))
  (assert (eq? (at lst 2) 6)))

(deftest partial-functions
  (defn add (a b)
    (+ a b))
  (define add-one (partial add '(1) ))
  (define two (add-one 1))
  (assert (eq? two 2)))

(defrec sum-below (x sum)
 (if (eq? x 0)
   sum
   (sum-below (- x 1) (+ sum x))))

(deftest trampoline-rec
 (assert (eq? 6 (sum-below 3 0))))

(deftest trampoline-rec-big
 (assert (eq? 5000050000 (sum-below 100000 0))))

;; ---------------------------------------------------------------
;; language behaviour

;; arithmetic and comparison
(deftest arith--variadic
  (assert (eq? 10 (+ 1 2 3 4)))
  (assert (eq? 4 (- 10 3 2 1)))
  (assert (eq? 24 (* 1 2 3 4)))
  (assert (eq? 2.5 (/ 5 2)))
  (assert (eq? -3 (- 0 3))))

(deftest arith--comparisons
  (assert (< 1 2)) (assert (> 3 2)) (assert (<= 2 2)) (assert (>= 2 2))
  (assert (not (< 2 1))) (assert (not (> 1 2))))

(deftest logic--and-or-not
  (assert (eq? 2 (&& 1 2)))
  (assert (eq? #f (&& #f 2)))
  (assert (eq? 1 (|| 1 2)))
  (assert (eq? 2 (|| #f 2)))
  (assert (not #f))
  (assert (eq? #t (not 0)))) ;; 0 is falsy (JS semantics)

(deftest numbers--large-and-fractional
  (assert (eq? 5000050000 (* 50000 100001)))
  (assert (eq? 0.5 (/ 1 2))))

;; strings
(deftest strings--concat
  (assert (eq? "foo bar" (+ "foo " "bar")))
  (assert (eq? "n=3" (+ "n=" 3)))
  (assert (eq? "abc" (+ "a" "b" "c"))))

(deftest strings--literals-are-not-symbols
  (define x 1)
  (assert (eq? "x" "x"))
  (assert (not (eq? "x" x))))

;; quote
(deftest quote--forms
  (assert (eq? 3 (len '(a b c))))
  (assert (eq? "a" (first '(a b c))))
  (assert (equal? '(1 2) (first '((1 2) 3))))
  (assert (list? '()))
  (assert (eq? "quote" (first (quote (quote x))))))

;; lists
(deftest lists--basics
  (define l (list 1 2 3))
  (assert (eq? 1 (car l)))
  (assert (equal? '(2 3) (cdr l)))
  (assert (equal? '(0 1 2 3) (cons 0 l)))
  (assert (eq? 3 (len l)))
  (assert (eq? 0 (len '())))
  (assert (empty? (cdr (cdr (cdr l)))))
  (assert (eq? nil (car '()))))

(deftest lists--cons-does-not-mutate
  (define l '(1 2))
  (define l2 (cons 0 l))
  (assert (eq? 2 (len l)))
  (assert (eq? 3 (len l2))))

(deftest lists--identity-vs-equality
  (define a '(1 2))
  (assert (eq? a a))
  (assert (not (eq? (list 1 2) (list 1 2))))
  (assert (equal? (list 1 2) (list 1 2))))

(deftest lists--higher-order
  (assert (equal? '(1 4 9) (map '(1 2 3) (lambda (x) (* x x)))))
  (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (+ acc x)) 0)))
  (assert (eq? 6 (r/reduce '(1 2 3) (lambda (x acc) (+ acc x)) 0)))
  (assert (equal? '(1 2 3 4) (concat '(1 2) '(3 4))))
  (assert (eq? 3 (len (zip '(1 2 3) '(4 5 6)))))
  (assert (equal? '(1 4) (first (zip '(1 2 3) '(4 5 6))))))

(deftest lists--iterate-visits-all
  (define total 0)
  (iterate '(1 2 3 4) (lambda (x) (set! total (+ total x))))
  (assert (eq? 10 total)))

;; scopes and closures
(deftest scope--lexical-closure
  (defn adder (n) (lambda (x) (+ x n)))
  (define add5 (adder 5))
  (define add7 (adder 7))
  (assert (eq? 15 (add5 10)))
  (assert (eq? 17 (add7 10))))

(deftest scope--closure-keeps-state
  (defn make-counter () (begin (define n 0) (lambda () (begin (set! n (+ n 1)) n))))
  (define c1 (make-counter))
  (define c2 (make-counter))
  (c1) (c1)
  (assert (eq? 3 (c1)))
  (assert (eq? 1 (c2))))

(deftest scope--set-updates-defining-scope
  (define v 1)
  (defn bump () (set! v (+ v 1)))
  (bump) (bump)
  (assert (eq? 3 v)))

(deftest scope--define-in-function-is-local
  (define shadow 1)
  (defn f () (begin (define shadow 2) shadow))
  (assert (eq? 2 (f)))
  (assert (eq? 1 shadow)))

(deftest scope--params-shadow-outer
  (define y 100)
  (defn g (y) (* y 2))
  (assert (eq? 6 (g 3)))
  (assert (eq? 100 y)))

;; functions
(deftest functions--recursion
  (defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
  (defn fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
  (assert (eq? 120 (fact 5)))
  (assert (eq? 55 (fib 10))))

(deftest functions--mutual-recursion
  (defn ev? (n) (if (eq? n 0) #t (od? (- n 1))))
  (defn od? (n) (if (eq? n 0) #f (ev? (- n 1))))
  (assert (ev? 10))
  (assert (od? 7)))

(deftest functions--higher-order-and-immediate-lambda
  (defn twice (f x) (f (f x)))
  (assert (eq? 12 (twice (lambda (x) (* x 2)) 3)))
  (assert (eq? 9 ((lambda (a b) (+ a b)) 4 5))))

(deftest functions--partial-application
  (define add3 (partial + '(1 2)))
  (assert (eq? 10 (add3 7)))
  (assert (equal? '(11 12) (map '(1 2) (partial + '(10))))))

;; control flow
(deftest control--if-branches
  (assert (eq? 1 (if #t 1 2)))
  (assert (eq? 2 (if #f 1 2)))
  (assert (eq? 1 (if 0 2 1)))
  (assert (eq? 2 (if '() 2 1))))

(deftest control--begin-sequences
  (define log '())
  (begin (set! log (cons 1 log)) (set! log (cons 2 log)))
  (assert (equal? '(2 1) log)))

;; errors
(deftest errors--try-catches-error-value
  (assert (eq? "boom" (try (lambda () (error "boom")) (lambda (e) e))))
  (assert (eq? 42 (try (lambda () 42) (lambda (e) 0)))))

(deftest errors--error-unwinds-nested-calls
  (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
  (assert (eq? "bottom" (try (lambda () (down 50)) (lambda (e) e))))
  (assert (eq? 3 (+ 1 2))))

;; macros
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (first (rest ast)) nil (first (rest (rest ast))))
      ast)))

(deftest macros--user-defined
  (assert (eq? 1 (unless #f 1)))
  (assert (eq? nil (unless #t 1))))

(deftest macros--defn-expands-to-lambda
  (defn sq (x) (* x x))
  (assert (eq? 49 (sq 7))))

;; church-encoded lists (closures as data)
(deftest church--lists
  (define cl (c/cons 1 (c/cons 2 (c/cons 3 nil))))
  (assert (eq? 1 (c/head cl)))
  (assert (eq? 3 (c/head (c/tail (c/tail cl))))))

;; tail calls stay flat; defrec works too
(deftest tail--defrec-loop
  (defrec count-down (n acc) (if (eq? n 0) acc (count-down (- n 1) (+ acc 1))))
  (assert (eq? 20000 (count-down 20000 0))))

;; ---------------------------------------------------------------
;; stack safety: pending work lives on the heap, not the C stack

(defrec nest (n acc) (if (eq? n 0) acc (nest (- n 1) (list acc))))

(deftest stack--deep-non-tail-recursion
  (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
  (assert (eq? 100000 (deep 100000))))

(deftest stack--long-tail-loop-without-defrec
  (defn count-up (n acc) (if (eq? n 0) acc (count-up (- n 1) (+ acc 1))))
  (assert (eq? 100000 (count-up 100000 0))))

(deftest stack--deep-mutual-recursion
  (defn ev? (n) (if (eq? n 0) #t (not (od? (- n 1)))))
  (defn od? (n) (if (eq? n 0) #f (not (ev? (- n 1)))))
  (assert (ev? 50000)))

(deftest stack--deep-data-build-print-free
  (defn build-and-drop () (len (nest 50000 '())))
  (assert (eq? 1 (build-and-drop)))
  (define printed (+ "" (nest 50000 '())))
  (assert (eq? printed printed)))

;; natives that call back into Lisp (map, reduce, partial, try, trampoline) are frames too

(deftest stack--deep-recursion-through-map-callbacks
  (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
  (assert (eq? 200000 (walk 200000))))

(deftest stack--deep-recursion-through-reduce-and-partial
  (defn rwalk (n) (if (eq? n 0) 0 (reduce '(1) (lambda (acc x) (+ acc x (rwalk (- n 1)))) 0)))
  (assert (eq? 100000 (rwalk 100000)))
  (defn pwalk (n) (if (eq? n 0) 0 (+ 1 ((partial pwalk (list (- n 1)))))))
  (assert (eq? 100000 (pwalk 100000)))
  (defn mwalk (n) (if (eq? n 0) 0 (+ 1 (first ((partial map (list '(1))) (lambda (x) (mwalk (- n 1))))))))
  (assert (eq? 100000 (mwalk 100000))))

(deftest stack--deeply-nested-try
  (defn tries (n) (if (eq? n 0) (error 0) (+ 1 (try (lambda () (tries (- n 1))) (lambda (e) e)))))
  (assert (eq? 100000 (tries 100000)))
  ;; every handler raises again: the error travels through all 100000 levels
  (defn rethrow (n) (if (eq? n 0) (error 0) (try (lambda () (rethrow (- n 1))) (lambda (e) (error (+ e 1))))))
  (assert (eq? 100000 (try (lambda () (rethrow 100000)) (lambda (e) e)))))

(deftest stack--error-deep-inside-map-callbacks-is-caught
  (defn mdown (n) (if (eq? n 0) (error "bottom") (+ 1 (first (map '(1) (lambda (x) (mdown (- n 1))))))))
  (assert (eq? "bottom" (try (lambda () (mdown 100000)) (lambda (e) e))))
  (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
  (assert (eq? 1000 (walk 1000)))
  (assert (equal? '(2 3) (map '(1 2) (lambda (x) (+ x 1))))))

(deftest errors--handler-that-raises
  (assert (eq? "ab" (try (lambda () (try (lambda () (error "a")) (lambda (e) (error (+ e "b"))))) (lambda (e) e))))
  (assert (eq? 1 (try (lambda () (try (lambda () 1) (lambda (e) (error "never")))) (lambda (e) "c"))))
  (assert (eq? "caught" (try (lambda () (try (lambda () (error "a")) 42)) (lambda (e) "caught")))))

(deftest errors--try-inside-map-inside-try
  (define r (try (lambda () (map '(1 2 3) (lambda (x) (try (lambda () (if (eq? x 2) (error "inner") x)) (lambda (e) e)))))
                 (lambda (e) "outer")))
  (assert (equal? '(1 inner 3) r))
  (define r2 (try (lambda () (map '(1 2 3) (lambda (x) (if (eq? x 2) (error "outer") x)))) (lambda (e) e)))
  (assert (eq? "outer" r2))
  (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (try (lambda () (error x)) (lambda (e) (+ acc e)))) 0))))

(deftest tail--defrec-after-error-inside-callbacks
  (defrec dloop (n acc) (if (eq? n 0) (error acc) (dloop (- n 1) (+ acc (first (map '(1) (lambda (x) x)))))))
  (assert (eq? 1000 (try (lambda () (dloop 1000 0)) (lambda (e) e))))
  (defrec ok (n acc) (if (eq? n 0) acc (ok (- n 1) (+ acc 1))))
  (assert (eq? 5 (first (map '(1) (lambda (x) (try (lambda () (dloop 5 0)) (lambda (e) e)))))))
  (assert (eq? 3000 (ok 3000 0)))
  (assert (eq? 7 (try (lambda () (dloop 7 0)) (lambda (e) e)))))

(deftest stack--error-deep-inside-recursion-unwinds
  (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
  (assert (eq? "bottom" (try (lambda () (down 50000)) (lambda (e) e))))
  (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
  (assert (eq? 1000 (deep 1000))))

;; ---------------------------------------------------------------
;; regressions

(deftest tail--defrec-works-again-after-a-caught-error
  (defrec guarded (n) (if (< n 1) (error "boom") n))
  (assert (eq? "boom" (try (lambda () (guarded 0)) (lambda (e) e))))
  (assert (eq? 5 (guarded 5))))

(deftest errors--define-and-set-need-a-name
  (assert (eq? "caught" (try (lambda () (define)) (lambda (e) "caught"))))
  (assert (eq? "caught" (try (lambda () (set!)) (lambda (e) "caught"))))
  (assert (eq? nil nil)))

;; math, strings and files
(deftest math--primitives
  (assert (eq? (exp 0) 1))
  (assert (eq? (log 1) 0))
  (assert (eq? (sqrt 9) 3))
  (assert (eq? (cos 0) 1))
  (assert (eq? (floor 2.7) 2))
  (assert (eq? (floor -0.5) -1)))

(deftest split--by-separator-and-characters
  (assert (equal? (split "a,b,,c" ",") '(a b "" c)))
  (assert (equal? (split "abc" "") '(a b c))))

(deftest files--write-read-load
  (write-file "/tmp/tinylisp-spec.lisp" "(define loaded-by-spec (+ 40 2))")
  (assert (eq? (read-file "/tmp/tinylisp-spec.lisp") "(define loaded-by-spec (+ 40 2))"))
  (load "/tmp/tinylisp-spec.lisp")
  (assert (eq? loaded-by-spec 42)))

(deftest files--errors-can-be-caught
  (assert (eq? "caught" (try (lambda () (read-file "/nonexistent/file")) (lambda (e) "caught"))))
  (assert (eq? "caught" (try (lambda () (load "/nonexistent/file")) (lambda (e) "caught")))))

;; macro expansions are cached per node; redefining a macro must invalidate them
(define macro/probe (lambda (ast) (if (eq? (first ast) "probe") (list "+" (first (rest ast)) (first (rest ast))) ast)))
(defn use-twice () (probe 4))
(define twice-before (use-twice))
(define twice-again (use-twice))
(define macro/probe (lambda (ast) (if (eq? (first ast) "probe") (list "*" (first (rest ast)) 10) ast)))
(define twice-after (use-twice))
(deftest macros--cache-is-cleared-when-a-macro-changes
  (assert (eq? twice-before 8))
  (assert (eq? twice-again 8))
  (assert (eq? twice-after 40)))

;; compiled code resolves names at run time: a define inside a function can shadow a global that was already used
(define shadowed 1)
(defn shadow-later (flag)
  (begin
    (define before shadowed)
    (if flag (define shadowed 2) 0)
    (list before shadowed)))
(define shadow-off (shadow-later 0))
(define shadow-on (shadow-later 1))
(define shadow-off-again (shadow-later 0))
(deftest scope--define-after-use-shadows-a-global
  (assert (equal? shadow-off (list 1 1)))
  (assert (equal? shadow-on (list 1 2)))
  (assert (equal? shadow-off-again (list 1 1)))
  (assert (eq? shadowed 1)))

(define counter 0)
(defn bump () (set! counter (+ counter 1)))
(bump)
(bump)
(deftest scope--set-reaches-globals-and-closures
  (assert (eq? counter 2))
  (define make (lambda (n) (lambda () (begin (set! n (+ n 1)) n))))
  (define c (make 10))
  (c)
  (assert (eq? (c) 12)))

;; values are NaN-boxed: numbers, NaN and the other types must stay apart
(deftest values--numbers-nan-and-types
  (assert (eq? (/ 1 4) 0.25))
  (assert (eq? (- 0 0) 0))
  (assert (eq? #f (eq? (/ 0 0) (/ 0 0))))
  (assert (eq? #f (eq? 1 "1")))
  (assert (eq? #t (list? (list 1))))
  (assert (eq? #f (list? 1)))
  (assert (eq? "ab" (+ "a" "b")))
  (assert (> (* 1e150 1e150) 1e299))
  (assert (eq? #t (> (* 1e300 1e300) 1e308)))
  (assert (eq? (len (list 1 2 3)) 3)))

;; vset! stores into a list in place; concat copies once
(deftest lists--vset-and-concat
  (define v (list 1 2 3))
  (assert (eq? 9 (vset! v 1 9)))
  (assert (equal? v (list 1 9 3)))
  (assert (eq? "caught" (try (lambda () (vset! v 3 0)) (lambda (e) "caught"))))
  (assert (equal? (concat (list 1) '() (list 2 3)) (list 1 2 3)))
  (assert (equal? (concat) '())))

;; a scope is recycled when its call ends, unless a closure captured it
(defn make-counter (n) (lambda () (begin (set! n (+ n 1)) n)))
(defn noise (x) (list x x))
(deftest scopes--recycled-without-breaking-closures
  (define c1 (make-counter 10))
  (define c2 (make-counter 100))
  (noise 1)
  (noise 2)
  (c1)
  (noise 3)
  (assert (eq? (c1) 12))
  (assert (eq? (c2) 101)))

;; defn takes a body of several expressions; for and for/list are loops with Python's shape
(defn sum-squares (a b)
  (define sa (* a a))
  (define sb (* b b))
  (+ sa sb))
(deftest macros--defn-with-several-expressions
  (assert (eq? 25 (sum-squares 3 4))))

(deftest macros--for-and-for-list
  (define total 0)
  (for (x '(1 2 3)) (set! total (+ total x)) (set! total (+ total 10)))
  (assert (eq? 36 total))
  (assert (equal? '(1 4 9) (for/list (x '(1 2 3)) (* x x))))
  (define grid (for/list (i (range 2)) (for/list (j (range 2)) (+ i j))))
  (assert (equal? '(0 1) (first grid)))
  (assert (equal? '(1 2) (first (rest grid))))
  (assert (equal? '() (for/list (x '()) x))))

;; a pattern takes each item apart; over (zip ...) the lists are walked side by side
(deftest macros--for-patterns-and-zip
  (define total 0)
  (assert (equal? '(5 7 9) (for/list ((a b) (zip '(1 2 3) '(4 5 6))) (+ a b))))
  (assert (equal? '(3 7) (for/list ((a b) '((1 2) (3 4))) (+ a b))))
  (for ((a b) (zip '(1 2) '(3 4))) (set! total (+ total (* a b))))
  (assert (eq? 11 total)))

(deftest lists--range-zip-and-multi-list-map
  (assert (equal? '(0 1 2) (range 3)))
  (assert (equal? '() (range 0)))
  (assert (eq? 3 (len (range 3))))
  (assert (equal? '(11 22) (map '(1 2 3) '(10 20) +)))
  (assert (equal? '(9 12) (map '(1 2) '(3 4) '(5 6) (lambda (a b c) (+ a b c)))))
  (assert (eq? 2 (len (zip '(1 2 3) '(4 5)))))
  (assert (eq? 100000 (len (range 100000))))
  (assert (eq? 0 (first (for/list (i (range 100000)) 0)))))

;; -> threads a value through steps; chain builds a function from blocks; fn is a lambda with a longer body
(defn inc (x) (+ x 1))
(defn times (x n) (* x n))
(deftest macros--thread-and-chain
  (assert (eq? 41 (-> 3 inc (times 10) inc)))
  (assert (eq? 3 (-> 3)))
  (define f (chain inc (lambda (x) (* x 2)) (chain inc inc)))
  (assert (eq? 6 (f 1)))
  (assert (eq? 6 ((chain inc) 5)))
  (define scale (fn (x) (define k 3) (* x k)))
  (assert (eq? 11 ((chain scale inc inc) 3))))

;; examples/autograd.lisp: (val ...) is Python's arithmetic on values, with the same graph
(load "examples/autograd.lisp")
(defn close? (x y) (< (- x y) 0.000001))
(deftest macros--val-infix
  (define a (param 2))
  (define b (param 3))
  (define y (val a * b + 0.5 - (a + b) ** 2 / 5))
  (assert (close? (data y) 1.5))
  (backward y)
  (assert (close? (grad a) 1))
  (assert (close? (grad b) 0))
  (assert (eq? (data (val - a)) -2))
  (assert (eq? (data (val 10 + a)) 12))
  (assert (eq? a (first (children (val 10 * a)))))
  (assert (eq? (val - 3) -3)))

(run-tests)
