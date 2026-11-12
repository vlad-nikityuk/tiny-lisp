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
  (begin
   (define res (empty? '()))
   (assert (eq? #t res))))

(deftest empty?--false
  (begin
   (define res (empty? '(1 2)))
   (assert (eq? #f res))))


;; list?
(deftest list?-empty
  (begin
   (define res (list? '()))
   (assert (eq? #t res))))

(deftest list?-with-elements
  (begin
   (define res (list? '(1 2 3)))
   (assert (eq? #t res))))

(deftest list?-non-list
  (begin
   (define res (list? 1))
   (assert (eq? #f res))))

(deftest concat-arrays
  (begin
   (define res (concat '(4 5 6) '(1 2 3)))
   (assert (equal? '(4 5 6 1 2 3) res))))

(deftest equality
  (begin
    (assert (eq? #t #t)
    (assert (eq? 4 4)))))

(deftest first-returns-head-of-list
  (begin
   (define lst '(4 5 6))
   (define fst (first lst))
   (assert (eq? fst 4)))
)

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
  (begin
   (define lst '(4 5 6))
   (assert (eq? (at lst 0) 4))
   (assert (eq? (at lst 1) 5))
   (assert (eq? (at lst 2) 6))
  ))

(deftest partial-functions
  (begin
    (defn add (a b)
      (+ a b))
    (define add-one (partial add '(1) ))
    (define two (add-one 1))
    (assert (eq? two 2))))

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
  (begin
    (assert (eq? 10 (+ 1 2 3 4)))
    (assert (eq? 4 (- 10 3 2 1)))
    (assert (eq? 24 (* 1 2 3 4)))
    (assert (eq? 2.5 (/ 5 2)))
    (assert (eq? -3 (- 0 3)))))

(deftest arith--comparisons
  (begin
    (assert (< 1 2)) (assert (> 3 2)) (assert (<= 2 2)) (assert (>= 2 2))
    (assert (not (< 2 1))) (assert (not (> 1 2)))))

(deftest logic--and-or-not
  (begin
    (assert (eq? 2 (&& 1 2)))
    (assert (eq? #f (&& #f 2)))
    (assert (eq? 1 (|| 1 2)))
    (assert (eq? 2 (|| #f 2)))
    (assert (not #f))
    (assert (eq? #t (not 0))))) ;; 0 is falsy (JS semantics)

(deftest numbers--large-and-fractional
  (begin
    (assert (eq? 5000050000 (* 50000 100001)))
    (assert (eq? 0.5 (/ 1 2)))))

;; strings
(deftest strings--concat
  (begin
    (assert (eq? "foo bar" (+ "foo " "bar")))
    (assert (eq? "n=3" (+ "n=" 3)))
    (assert (eq? "abc" (+ "a" "b" "c")))))

(deftest strings--literals-are-not-symbols
  (begin
    (define x 1)
    (assert (eq? "x" "x"))
    (assert (not (eq? "x" x)))))

;; quote
(deftest quote--forms
  (begin
    (assert (eq? 3 (len '(a b c))))
    (assert (eq? "a" (first '(a b c))))
    (assert (equal? '(1 2) (first '((1 2) 3))))
    (assert (list? '()))
    (assert (eq? "quote" (first (quote (quote x)))))))

;; lists
(deftest lists--basics
  (begin
    (define l (list 1 2 3))
    (assert (eq? 1 (car l)))
    (assert (equal? '(2 3) (cdr l)))
    (assert (equal? '(0 1 2 3) (cons 0 l)))
    (assert (eq? 3 (len l)))
    (assert (eq? 0 (len '())))
    (assert (empty? (cdr (cdr (cdr l)))))
    (assert (eq? nil (car '())))))

(deftest lists--cons-does-not-mutate
  (begin
    (define l '(1 2))
    (define l2 (cons 0 l))
    (assert (eq? 2 (len l)))
    (assert (eq? 3 (len l2)))))

(deftest lists--identity-vs-equality
  (begin
    (define a '(1 2))
    (assert (eq? a a))
    (assert (not (eq? (list 1 2) (list 1 2))))
    (assert (equal? (list 1 2) (list 1 2)))))

(deftest lists--higher-order
  (begin
    (assert (equal? '(1 4 9) (map '(1 2 3) (lambda (x) (* x x)))))
    (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (+ acc x)) 0)))
    (assert (eq? 6 (r/reduce '(1 2 3) (lambda (x acc) (+ acc x)) 0)))
    (assert (equal? '(1 2 3 4) (concat '(1 2) '(3 4))))
    (assert (eq? 3 (len (zip '(1 2 3) '(4 5 6)))))
    (assert (equal? '(1 4) (first (zip '(1 2 3) '(4 5 6)))))))

(deftest lists--iterate-visits-all
  (begin
    (define total 0)
    (iterate '(1 2 3 4) (lambda (x) (set! total (+ total x))))
    (assert (eq? 10 total))))

;; scopes and closures
(deftest scope--lexical-closure
  (begin
    (defn adder (n) (lambda (x) (+ x n)))
    (define add5 (adder 5))
    (define add7 (adder 7))
    (assert (eq? 15 (add5 10)))
    (assert (eq? 17 (add7 10)))))

(deftest scope--closure-keeps-state
  (begin
    (defn make-counter () (begin (define n 0) (lambda () (begin (set! n (+ n 1)) n))))
    (define c1 (make-counter))
    (define c2 (make-counter))
    (c1) (c1)
    (assert (eq? 3 (c1)))
    (assert (eq? 1 (c2)))))

(deftest scope--set-updates-defining-scope
  (begin
    (define v 1)
    (defn bump () (set! v (+ v 1)))
    (bump) (bump)
    (assert (eq? 3 v))))

(deftest scope--define-in-function-is-local
  (begin
    (define shadow 1)
    (defn f () (begin (define shadow 2) shadow))
    (assert (eq? 2 (f)))
    (assert (eq? 1 shadow))))

(deftest scope--params-shadow-outer
  (begin
    (define y 100)
    (defn g (y) (* y 2))
    (assert (eq? 6 (g 3)))
    (assert (eq? 100 y))))

;; functions
(deftest functions--recursion
  (begin
    (defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
    (defn fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
    (assert (eq? 120 (fact 5)))
    (assert (eq? 55 (fib 10)))))

(deftest functions--mutual-recursion
  (begin
    (defn ev? (n) (if (eq? n 0) #t (od? (- n 1))))
    (defn od? (n) (if (eq? n 0) #f (ev? (- n 1))))
    (assert (ev? 10))
    (assert (od? 7))))

(deftest functions--higher-order-and-immediate-lambda
  (begin
    (defn twice (f x) (f (f x)))
    (assert (eq? 12 (twice (lambda (x) (* x 2)) 3)))
    (assert (eq? 9 ((lambda (a b) (+ a b)) 4 5)))))

(deftest functions--partial-application
  (begin
    (define add3 (partial + '(1 2)))
    (assert (eq? 10 (add3 7)))
    (assert (equal? '(11 12) (map '(1 2) (partial + '(10)))))))

;; control flow
(deftest control--if-branches
  (begin
    (assert (eq? 1 (if #t 1 2)))
    (assert (eq? 2 (if #f 1 2)))
    (assert (eq? 1 (if 0 2 1)))
    (assert (eq? 2 (if '() 2 1)))))

(deftest control--begin-sequences
  (begin
    (define log '())
    (begin (set! log (cons 1 log)) (set! log (cons 2 log)))
    (assert (equal? '(2 1) log))))

;; errors
(deftest errors--try-catches-error-value
  (begin
    (assert (eq? "boom" (try (lambda () (error "boom")) (lambda (e) e))))
    (assert (eq? 42 (try (lambda () 42) (lambda (e) 0))))))

(deftest errors--error-unwinds-nested-calls
  (begin
    (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
    (assert (eq? "bottom" (try (lambda () (down 50)) (lambda (e) e))))
    (assert (eq? 3 (+ 1 2)))))

;; macros
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (first (rest ast)) nil (first (rest (rest ast))))
      ast)))

(deftest macros--user-defined
  (begin
    (assert (eq? 1 (unless #f 1)))
    (assert (eq? nil (unless #t 1)))))

(deftest macros--defn-expands-to-lambda
  (begin
    (defn sq (x) (* x x))
    (assert (eq? 49 (sq 7)))))

;; church-encoded lists (closures as data)
(deftest church--lists
  (begin
    (define cl (c/cons 1 (c/cons 2 (c/cons 3 nil))))
    (assert (eq? 1 (c/head cl)))
    (assert (eq? 3 (c/head (c/tail (c/tail cl)))))))

;; tail calls stay flat; defrec works too
(deftest tail--defrec-loop
  (begin
    (defrec count-down (n acc) (if (eq? n 0) acc (count-down (- n 1) (+ acc 1))))
    (assert (eq? 20000 (count-down 20000 0)))))

;; ---------------------------------------------------------------
;; stack safety: pending work lives on the heap, not the C stack

(defrec nest (n acc) (if (eq? n 0) acc (nest (- n 1) (list acc))))

(deftest stack--deep-non-tail-recursion
  (begin
    (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
    (assert (eq? 100000 (deep 100000)))))

(deftest stack--long-tail-loop-without-defrec
  (begin
    (defn count-up (n acc) (if (eq? n 0) acc (count-up (- n 1) (+ acc 1))))
    (assert (eq? 100000 (count-up 100000 0)))))

(deftest stack--deep-mutual-recursion
  (begin
    (defn ev? (n) (if (eq? n 0) #t (not (od? (- n 1)))))
    (defn od? (n) (if (eq? n 0) #f (not (ev? (- n 1)))))
    (assert (ev? 50000))))

(deftest stack--deep-data-build-print-free
  (begin
    (defn build-and-drop () (len (nest 50000 '())))
    (assert (eq? 1 (build-and-drop)))
    (define printed (+ "" (nest 50000 '())))
    (assert (eq? printed printed))))

;; natives that call back into Lisp (map, reduce, partial, try, trampoline) are frames too

(deftest stack--deep-recursion-through-map-callbacks
  (begin
    (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
    (assert (eq? 200000 (walk 200000)))))

(deftest stack--deep-recursion-through-reduce-and-partial
  (begin
    (defn rwalk (n) (if (eq? n 0) 0 (reduce '(1) (lambda (acc x) (+ acc x (rwalk (- n 1)))) 0)))
    (assert (eq? 100000 (rwalk 100000)))
    (defn pwalk (n) (if (eq? n 0) 0 (+ 1 ((partial pwalk (list (- n 1)))))))
    (assert (eq? 100000 (pwalk 100000)))
    (defn mwalk (n) (if (eq? n 0) 0 (+ 1 (first ((partial map (list '(1))) (lambda (x) (mwalk (- n 1))))))))
    (assert (eq? 100000 (mwalk 100000)))))

(deftest stack--deeply-nested-try
  (begin
    (defn tries (n) (if (eq? n 0) (error 0) (+ 1 (try (lambda () (tries (- n 1))) (lambda (e) e)))))
    (assert (eq? 100000 (tries 100000)))
    ;; every handler raises again: the error travels through all 100000 levels
    (defn rethrow (n) (if (eq? n 0) (error 0) (try (lambda () (rethrow (- n 1))) (lambda (e) (error (+ e 1))))))
    (assert (eq? 100000 (try (lambda () (rethrow 100000)) (lambda (e) e))))))

(deftest stack--error-deep-inside-map-callbacks-is-caught
  (begin
    (defn mdown (n) (if (eq? n 0) (error "bottom") (+ 1 (first (map '(1) (lambda (x) (mdown (- n 1))))))))
    (assert (eq? "bottom" (try (lambda () (mdown 100000)) (lambda (e) e))))
    (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
    (assert (eq? 1000 (walk 1000)))
    (assert (equal? '(2 3) (map '(1 2) (lambda (x) (+ x 1)))))))

(deftest errors--handler-that-raises
  (begin
    (assert (eq? "ab" (try (lambda () (try (lambda () (error "a")) (lambda (e) (error (+ e "b"))))) (lambda (e) e))))
    (assert (eq? 1 (try (lambda () (try (lambda () 1) (lambda (e) (error "never")))) (lambda (e) "c"))))
    (assert (eq? "caught" (try (lambda () (try (lambda () (error "a")) 42)) (lambda (e) "caught"))))))

(deftest errors--try-inside-map-inside-try
  (begin
    (define r (try (lambda () (map '(1 2 3) (lambda (x) (try (lambda () (if (eq? x 2) (error "inner") x)) (lambda (e) e)))))
                   (lambda (e) "outer")))
    (assert (equal? '(1 inner 3) r))
    (define r2 (try (lambda () (map '(1 2 3) (lambda (x) (if (eq? x 2) (error "outer") x)))) (lambda (e) e)))
    (assert (eq? "outer" r2))
    (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (try (lambda () (error x)) (lambda (e) (+ acc e)))) 0)))))

(deftest tail--defrec-after-error-inside-callbacks
  (begin
    (defrec dloop (n acc) (if (eq? n 0) (error acc) (dloop (- n 1) (+ acc (first (map '(1) (lambda (x) x)))))))
    (assert (eq? 1000 (try (lambda () (dloop 1000 0)) (lambda (e) e))))
    (defrec ok (n acc) (if (eq? n 0) acc (ok (- n 1) (+ acc 1))))
    (assert (eq? 5 (first (map '(1) (lambda (x) (try (lambda () (dloop 5 0)) (lambda (e) e)))))))
    (assert (eq? 3000 (ok 3000 0)))
    (assert (eq? 7 (try (lambda () (dloop 7 0)) (lambda (e) e))))))

(deftest stack--error-deep-inside-recursion-unwinds
  (begin
    (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
    (assert (eq? "bottom" (try (lambda () (down 50000)) (lambda (e) e))))
    (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
    (assert (eq? 1000 (deep 1000)))))

;; ---------------------------------------------------------------
;; regressions

(deftest tail--defrec-works-again-after-a-caught-error
  (begin
    (defrec guarded (n) (if (< n 1) (error "boom") n))
    (assert (eq? "boom" (try (lambda () (guarded 0)) (lambda (e) e))))
    (assert (eq? 5 (guarded 5)))))

(deftest errors--define-and-set-need-a-name
  (begin
    (assert (eq? "caught" (try (lambda () (define)) (lambda (e) "caught"))))
    (assert (eq? "caught" (try (lambda () (set!)) (lambda (e) "caught"))))
    (assert (eq? nil nil))))

(run-tests)
