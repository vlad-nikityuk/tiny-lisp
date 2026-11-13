;; deftest
;; 1. unfolds to (define (lambda ... ))
;; 2. adds itself to *TESTS* test list
;; 3. Adds expr: and test: to assert call


;; eq? tests
(deftest "eq?: zero is zero"
  (assert (eq? 0 0)))

(deftest "eq?: nil is nil"
  (assert (eq? nil nil)))

(deftest "eq?: empty list is nil"
  (assert (eq? nil '()) ))


;; empty?
(deftest "empty?: true"
  (define res (empty? '()))
  (assert (eq? #t res)))

(deftest "empty?: false"
  (define res (empty? '(1 2)))
  (assert (eq? #f res)))


;; list?
(deftest "list?: empty"
  (define res (list? '()))
  (assert (eq? #t res)))

(deftest "list?: with elements"
  (define res (list? '(1 2 3)))
  (assert (eq? #t res)))

(deftest "list?: non-list"
  (define res (list? 1))
  (assert (eq? #f res)))

(deftest "lists: concat arrays"
  (define res (concat '(4 5 6) '(1 2 3)))
  (assert (equal? '(4 5 6 1 2 3) res)))

(deftest "eq?: booleans and numbers"
  (assert (eq? #t #t))
  (assert (eq? 4 4)))

(deftest "lists: first is the head"
  (define lst '(4 5 6))
  (define fst (first lst))
  (assert (eq? fst 4)))

(deftest "control: begin returns the last expression"
  (assert (eq? 4 (begin 1 2 3 4))))

;; equal? compares element-wise at any depth, and lists of different lengths differ
(deftest "equal?: deep and length"
  (assert (equal? '(1 2) '(1 2)))
  (assert (not (equal? '(1 2) '(1 3))))
  (assert (not (equal? '(2 1) '(1 1))))
  (assert (not (equal? '(1 2 3) '(1 2))))
  (assert (not (equal? '(1 2) '(1 2 3))))
  (assert (equal? '((1 2) (3 (4))) '((1 2) (3 (4)))))
  (assert (not (equal? '((1 2) (3 (4))) '((1 2) (3 (5))))))
  (assert (equal? '() '()))
  (assert (not (equal? '(1) 1))))

;; deftest rewrites (assert expr) to (assert expr 'test-name 'expr), so a failure names the test and the expression
(deftest "asserts: patched with test name and expression"
  (assert (equal? (patch-asserts '(assert (eq? 1 x)) 'my-test)
                  (list "assert" '(eq? 1 x) (list "quote" 'my-test) (list "quote" '(eq? 1 x)))))
  (assert (equal? (patch-asserts '(assert 1 msg) 't)
                  (list "assert" 1 (list "quote" 't) (list "quote" 1) 'msg)))
  (assert (equal? (patch-asserts '(quote (assert 1)) 't) '(quote (assert 1))))
  (assert (equal? (patch-asserts '(a (b (assert 2))) 't)
                  (list 'a (list 'b (list "assert" 2 (list "quote" 't) (list "quote" 2)))))))

(defn bare-assert () (assert #f))
(deftest "asserts: failure message"
  (define message (try (lambda () (assert (eq? 1 2) "extra")) (lambda (e) e)))
  (assert (eq? message "assertion failed in asserts: failure message: (eq? 1 2) extra"))
  (assert (eq? "assertion-failed" (try bare-assert (lambda (e) e)))))

(deftest "asserts: fails on a false expression"
  (if
    (eq?
      (try
        (lambda () (begin (assert #f) #f))
        (lambda (e) #t))
      #t)
    (pass)
    (error 'oh-dear)))

(deftest "lists: at indexes from zero"
  (define lst '(4 5 6))
  (assert (eq? (at lst 0) 4))
  (assert (eq? (at lst 1) 5))
  (assert (eq? (at lst 2) 6)))

(deftest "functions: partial fixes leading arguments"
  (defn add (a b)
    (+ a b))
  (define add-one (partial add '(1) ))
  (define two (add-one 1))
  (assert (eq? two 2)))

(defrec sum-below (x sum)
 (if (eq? x 0)
   sum
   (sum-below (- x 1) (+ sum x))))

(deftest "tail: defrec small"
 (assert (eq? 6 (sum-below 3 0))))

(deftest "tail: defrec 100000 deep"
 (assert (eq? 5000050000 (sum-below 100000 0))))

;; ---------------------------------------------------------------
;; language behaviour

;; arithmetic and comparison
(deftest "arith: variadic"
  (assert (eq? 10 (+ 1 2 3 4)))
  (assert (eq? 4 (- 10 3 2 1)))
  (assert (eq? 24 (* 1 2 3 4)))
  (assert (eq? 2.5 (/ 5 2)))
  (assert (eq? -3 (- 0 3))))

(deftest "arith: comparisons"
  (assert (< 1 2)) (assert (> 3 2)) (assert (<= 2 2)) (assert (>= 2 2))
  (assert (not (< 2 1))) (assert (not (> 1 2))))

(deftest "logic: and or not"
  (assert (eq? 2 (&& 1 2)))
  (assert (eq? #f (&& #f 2)))
  (assert (eq? 1 (|| 1 2)))
  (assert (eq? 2 (|| #f 2)))
  (assert (not #f))
  (assert (eq? #t (not 0)))) ;; 0 is falsy (JS semantics)

(deftest "numbers: large and fractional"
  (assert (eq? 5000050000 (* 50000 100001)))
  (assert (eq? 0.5 (/ 1 2))))

;; strings
(deftest "strings: concat"
  (assert (eq? "foo bar" (+ "foo " "bar")))
  (assert (eq? "n=3" (+ "n=" 3)))
  (assert (eq? "abc" (+ "a" "b" "c"))))

(deftest "strings: literals are not symbols"
  (define x 1)
  (assert (eq? "x" "x"))
  (assert (not (eq? "x" x))))

;; quote
(deftest "quote: forms"
  (assert (eq? 3 (len '(a b c))))
  (assert (eq? "a" (first '(a b c))))
  (assert (equal? '(1 2) (first '((1 2) 3))))
  (assert (list? '()))
  (assert (eq? "quote" (first (quote (quote x))))))

;; lists
(deftest "lists: basics"
  (define l (list 1 2 3))
  (assert (eq? 1 (car l)))
  (assert (equal? '(2 3) (cdr l)))
  (assert (equal? '(0 1 2 3) (cons 0 l)))
  (assert (eq? 3 (len l)))
  (assert (eq? 0 (len '())))
  (assert (empty? (cdr (cdr (cdr l)))))
  (assert (eq? nil (car '()))))

(deftest "lists: cons does not mutate"
  (define l '(1 2))
  (define l2 (cons 0 l))
  (assert (eq? 2 (len l)))
  (assert (eq? 3 (len l2))))

(deftest "lists: identity vs equality"
  (define a '(1 2))
  (assert (eq? a a))
  (assert (not (eq? (list 1 2) (list 1 2))))
  (assert (equal? (list 1 2) (list 1 2))))

(deftest "lists: higher order"
  (assert (equal? '(1 4 9) (map '(1 2 3) (lambda (x) (* x x)))))
  (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (+ acc x)) 0)))
  (assert (eq? 6 (r/reduce '(1 2 3) (lambda (x acc) (+ acc x)) 0)))
  (assert (equal? '(1 2 3 4) (concat '(1 2) '(3 4))))
  (assert (eq? 3 (len (zip '(1 2 3) '(4 5 6)))))
  (assert (equal? '(1 4) (first (zip '(1 2 3) '(4 5 6))))))

(deftest "lists: iterate visits all"
  (define total 0)
  (iterate '(1 2 3 4) (lambda (x) (set! total (+ total x))))
  (assert (eq? 10 total)))

;; scopes and closures
(deftest "scope: lexical closure"
  (defn adder (n) (lambda (x) (+ x n)))
  (define add5 (adder 5))
  (define add7 (adder 7))
  (assert (eq? 15 (add5 10)))
  (assert (eq? 17 (add7 10))))

(deftest "scope: closure keeps state"
  (defn make-counter () (begin (define n 0) (lambda () (begin (set! n (+ n 1)) n))))
  (define c1 (make-counter))
  (define c2 (make-counter))
  (c1) (c1)
  (assert (eq? 3 (c1)))
  (assert (eq? 1 (c2))))

(deftest "scope: set updates defining scope"
  (define v 1)
  (defn bump () (set! v (+ v 1)))
  (bump) (bump)
  (assert (eq? 3 v)))

(deftest "scope: define in function is local"
  (define shadow 1)
  (defn f () (begin (define shadow 2) shadow))
  (assert (eq? 2 (f)))
  (assert (eq? 1 shadow)))

(deftest "scope: params shadow outer"
  (define y 100)
  (defn g (y) (* y 2))
  (assert (eq? 6 (g 3)))
  (assert (eq? 100 y)))

;; functions
(deftest "functions: recursion"
  (defn fact (n) (if (<= n 1) 1 (* n (fact (- n 1)))))
  (defn fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
  (assert (eq? 120 (fact 5)))
  (assert (eq? 55 (fib 10))))

(deftest "functions: mutual recursion"
  (defn ev? (n) (if (eq? n 0) #t (od? (- n 1))))
  (defn od? (n) (if (eq? n 0) #f (ev? (- n 1))))
  (assert (ev? 10))
  (assert (od? 7)))

(deftest "functions: higher order and immediate lambda"
  (defn twice (f x) (f (f x)))
  (assert (eq? 12 (twice (lambda (x) (* x 2)) 3)))
  (assert (eq? 9 ((lambda (a b) (+ a b)) 4 5))))

(deftest "functions: partial application"
  (define add3 (partial + '(1 2)))
  (assert (eq? 10 (add3 7)))
  (assert (equal? '(11 12) (map '(1 2) (partial + '(10))))))

;; control flow
(deftest "control: if branches"
  (assert (eq? 1 (if #t 1 2)))
  (assert (eq? 2 (if #f 1 2)))
  (assert (eq? 1 (if 0 2 1)))
  (assert (eq? 2 (if '() 2 1))))

(deftest "control: begin sequences"
  (define log '())
  (begin (set! log (cons 1 log)) (set! log (cons 2 log)))
  (assert (equal? '(2 1) log)))

;; errors
(deftest "errors: try catches error value"
  (assert (eq? "boom" (try (lambda () (error "boom")) (lambda (e) e))))
  (assert (eq? 42 (try (lambda () 42) (lambda (e) 0)))))

(deftest "errors: error unwinds nested calls"
  (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
  (assert (eq? "bottom" (try (lambda () (down 50)) (lambda (e) e))))
  (assert (eq? 3 (+ 1 2))))

;; macros
(define macro/unless
  (lambda (ast)
    (if (eq? (first ast) "unless")
      (list "if" (first (rest ast)) nil (first (rest (rest ast))))
      ast)))

(deftest "macros: user defined"
  (assert (eq? 1 (unless #f 1)))
  (assert (eq? nil (unless #t 1))))

(deftest "macros: defn expands to lambda"
  (defn sq (x) (* x x))
  (assert (eq? 49 (sq 7))))

;; church-encoded lists (closures as data)
(defn c/cons (v lst) (lambda (f) (f v lst)))
(defn c/head (lst) (lst (lambda (h t) h)))
(defn c/tail (lst) (lst (lambda (h t) t)))
(deftest "closures: church lists"
  (define cl (c/cons 1 (c/cons 2 (c/cons 3 nil))))
  (assert (eq? 1 (c/head cl)))
  (assert (eq? 3 (c/head (c/tail (c/tail cl))))))

;; tail calls stay flat; defrec works too
(deftest "tail: defrec loop"
  (defrec count-down (n acc) (if (eq? n 0) acc (count-down (- n 1) (+ acc 1))))
  (assert (eq? 20000 (count-down 20000 0))))

;; ---------------------------------------------------------------
;; stack safety: pending work lives on the heap, not the C stack

(defrec nest (n acc) (if (eq? n 0) acc (nest (- n 1) (list acc))))

(deftest "stack: deep non tail recursion"
  (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
  (assert (eq? 100000 (deep 100000))))

(deftest "stack: long tail loop without defrec"
  (defn count-up (n acc) (if (eq? n 0) acc (count-up (- n 1) (+ acc 1))))
  (assert (eq? 100000 (count-up 100000 0))))

(deftest "stack: deep mutual recursion"
  (defn ev? (n) (if (eq? n 0) #t (not (od? (- n 1)))))
  (defn od? (n) (if (eq? n 0) #f (not (ev? (- n 1)))))
  (assert (ev? 50000)))

(deftest "stack: deep data build print free"
  (defn build-and-drop () (len (nest 50000 '())))
  (assert (eq? 1 (build-and-drop)))
  (define printed (+ "" (nest 50000 '())))
  (assert (eq? printed printed)))

;; natives that call back into Lisp (map, reduce, partial, try, trampoline) are frames too

(deftest "stack: deep recursion through map callbacks"
  (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
  (assert (eq? 200000 (walk 200000))))

(deftest "stack: deep recursion through reduce and partial"
  (defn rwalk (n) (if (eq? n 0) 0 (reduce '(1) (lambda (acc x) (+ acc x (rwalk (- n 1)))) 0)))
  (assert (eq? 100000 (rwalk 100000)))
  (defn pwalk (n) (if (eq? n 0) 0 (+ 1 ((partial pwalk (list (- n 1)))))))
  (assert (eq? 100000 (pwalk 100000)))
  (defn mwalk (n) (if (eq? n 0) 0 (+ 1 (first ((partial map (list '(1))) (lambda (x) (mwalk (- n 1))))))))
  (assert (eq? 100000 (mwalk 100000))))

(deftest "stack: deeply nested try"
  (defn tries (n) (if (eq? n 0) (error 0) (+ 1 (try (lambda () (tries (- n 1))) (lambda (e) e)))))
  (assert (eq? 100000 (tries 100000)))
  ;; every handler raises again: the error travels through all 100000 levels
  (defn rethrow (n) (if (eq? n 0) (error 0) (try (lambda () (rethrow (- n 1))) (lambda (e) (error (+ e 1))))))
  (assert (eq? 100000 (try (lambda () (rethrow 100000)) (lambda (e) e)))))

(deftest "stack: error deep inside map callbacks is caught"
  (defn mdown (n) (if (eq? n 0) (error "bottom") (+ 1 (first (map '(1) (lambda (x) (mdown (- n 1))))))))
  (assert (eq? "bottom" (try (lambda () (mdown 100000)) (lambda (e) e))))
  (defn walk (n) (if (eq? n 0) 0 (+ 1 (first (map '(1) (lambda (x) (walk (- n 1))))))))
  (assert (eq? 1000 (walk 1000)))
  (assert (equal? '(2 3) (map '(1 2) (lambda (x) (+ x 1))))))

(deftest "errors: handler that raises"
  (assert (eq? "ab" (try (lambda () (try (lambda () (error "a")) (lambda (e) (error (+ e "b"))))) (lambda (e) e))))
  (assert (eq? 1 (try (lambda () (try (lambda () 1) (lambda (e) (error "never")))) (lambda (e) "c"))))
  (assert (eq? "caught" (try (lambda () (try (lambda () (error "a")) 42)) (lambda (e) "caught")))))

(deftest "errors: try inside map inside try"
  (define r (try (lambda () (map '(1 2 3) (lambda (x) (try (lambda () (if (eq? x 2) (error "inner") x)) (lambda (e) e)))))
                 (lambda (e) "outer")))
  (assert (equal? '(1 inner 3) r))
  (define r2 (try (lambda () (map '(1 2 3) (lambda (x) (if (eq? x 2) (error "outer") x)))) (lambda (e) e)))
  (assert (eq? "outer" r2))
  (assert (eq? 6 (reduce '(1 2 3) (lambda (acc x) (try (lambda () (error x)) (lambda (e) (+ acc e)))) 0))))

(deftest "tail: defrec after error inside callbacks"
  (defrec dloop (n acc) (if (eq? n 0) (error acc) (dloop (- n 1) (+ acc (first (map '(1) (lambda (x) x)))))))
  (assert (eq? 1000 (try (lambda () (dloop 1000 0)) (lambda (e) e))))
  (defrec ok (n acc) (if (eq? n 0) acc (ok (- n 1) (+ acc 1))))
  (assert (eq? 5 (first (map '(1) (lambda (x) (try (lambda () (dloop 5 0)) (lambda (e) e)))))))
  (assert (eq? 3000 (ok 3000 0)))
  (assert (eq? 7 (try (lambda () (dloop 7 0)) (lambda (e) e)))))

(deftest "stack: error deep inside recursion unwinds"
  (defn down (n) (if (eq? n 0) (error "bottom") (+ 1 (down (- n 1)))))
  (assert (eq? "bottom" (try (lambda () (down 50000)) (lambda (e) e))))
  (defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
  (assert (eq? 1000 (deep 1000))))

;; ---------------------------------------------------------------
;; regressions

(deftest "tail: defrec works again after a caught error"
  (defrec guarded (n) (if (< n 1) (error "boom") n))
  (assert (eq? "boom" (try (lambda () (guarded 0)) (lambda (e) e))))
  (assert (eq? 5 (guarded 5))))

(deftest "errors: define and set need a name"
  (assert (eq? "caught" (try (lambda () (define)) (lambda (e) "caught"))))
  (assert (eq? "caught" (try (lambda () (set!)) (lambda (e) "caught"))))
  (assert (eq? nil nil)))

;; math, strings and files
(deftest "math: primitives"
  (assert (eq? (exp 0) 1))
  (assert (eq? (log 1) 0))
  (assert (eq? (sqrt 9) 3))
  (assert (eq? (cos 0) 1))
  (assert (eq? (floor 2.7) 2))
  (assert (eq? (floor -0.5) -1)))

(deftest "split: by separator and characters"
  (assert (equal? (split "a,b,,c" ",") (list 'a 'b "" 'c)))
  (assert (equal? (split "abc" "") '(a b c))))

(deftest "files: write read load"
  (write-file "/tmp/tinylisp-spec.lisp" "(define loaded-by-spec (+ 40 2))")
  (assert (eq? (read-file "/tmp/tinylisp-spec.lisp") "(define loaded-by-spec (+ 40 2))"))
  (load "/tmp/tinylisp-spec.lisp")
  (assert (eq? loaded-by-spec 42)))

(deftest "files: errors can be caught"
  (assert (eq? "caught" (try (lambda () (read-file "/nonexistent/file")) (lambda (e) "caught"))))
  (assert (eq? "caught" (try (lambda () (load "/nonexistent/file")) (lambda (e) "caught")))))

;; macro expansions are cached per node; redefining a macro must invalidate them
(define macro/probe (lambda (ast) (if (eq? (first ast) "probe") (list "+" (first (rest ast)) (first (rest ast))) ast)))
(defn use-twice () (probe 4))
(define twice-before (use-twice))
(define twice-again (use-twice))
(define macro/probe (lambda (ast) (if (eq? (first ast) "probe") (list "*" (first (rest ast)) 10) ast)))
(define twice-after (use-twice))
(deftest "macros: cache is cleared when a macro changes"
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
(deftest "scope: define after use shadows a global"
  (assert (equal? shadow-off (list 1 1)))
  (assert (equal? shadow-on (list 1 2)))
  (assert (equal? shadow-off-again (list 1 1)))
  (assert (eq? shadowed 1)))

(define counter 0)
(defn bump () (set! counter (+ counter 1)))
(bump)
(bump)
(deftest "scope: set reaches globals and closures"
  (assert (eq? counter 2))
  (define make (lambda (n) (lambda () (begin (set! n (+ n 1)) n))))
  (define c (make 10))
  (c)
  (assert (eq? (c) 12)))

;; values are NaN-boxed: numbers, NaN and the other types must stay apart
(deftest "values: numbers nan and types"
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
(deftest "lists: vset and concat"
  (define v (list 1 2 3))
  (assert (eq? 9 (vset! v 1 9)))
  (assert (equal? v (list 1 9 3)))
  (assert (eq? "caught" (try (lambda () (vset! v 3 0)) (lambda (e) "caught"))))
  (assert (equal? (concat (list 1) '() (list 2 3)) (list 1 2 3)))
  (assert (equal? (concat) '())))

;; a scope is recycled when its call ends, unless a closure captured it
(defn make-counter (n) (lambda () (begin (set! n (+ n 1)) n)))
(defn noise (x) (list x x))
(deftest "scopes: recycled without breaking closures"
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
(deftest "macros: defn with several expressions"
  (assert (eq? 25 (sum-squares 3 4))))

(deftest "macros: for and for list"
  (define total 0)
  (for (x '(1 2 3)) (set! total (+ total x)) (set! total (+ total 10)))
  (assert (eq? 36 total))
  (assert (equal? '(1 4 9) (for/list (x '(1 2 3)) (* x x))))
  (define grid (for/list (i (range 2)) (for/list (j (range 2)) (+ i j))))
  (assert (equal? '(0 1) (first grid)))
  (assert (equal? '(1 2) (first (rest grid))))
  (assert (equal? '() (for/list (x '()) x))))

;; a pattern takes each item apart; over (zip ...) the lists are walked side by side
(deftest "macros: for patterns and zip"
  (define total 0)
  (assert (equal? '(5 7 9) (for/list ((a b) (zip '(1 2 3) '(4 5 6))) (+ a b))))
  (assert (equal? '(3 7) (for/list ((a b) '((1 2) (3 4))) (+ a b))))
  (for ((a b) (zip '(1 2) '(3 4))) (set! total (+ total (* a b))))
  (assert (eq? 11 total)))

;; apply spreads a list into arguments; filter keeps the items a predicate accepts; flatten joins one level
(deftest "lists: apply filter flatten"
  (assert (eq? 6 (apply + '(1 2 3))))
  (assert (equal? '(1 2 3) (apply concat '((1) (2 3)))))
  (assert (equal? (list 1 '(2 3)) (apply (lambda (a & r) (list a r)) '(1 2 3))))
  (assert (equal? '() (apply list '())))
  (assert (equal? '(2 4) (filter '(1 2 3 4) (lambda (x) (eq? 0 (- x (* 2 (floor (/ x 2)))))))))
  (assert (equal? '() (filter '() (lambda (x) #t))))
  (assert (equal? '(1 2 3) (flatten '((1 2) () (3)))))
  (assert (eq? 100000 (len (flatten (for/list (i (range 100000)) (list i)))))))

(deftest "lists: range zip and multi-list map"
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
(deftest "macros: thread and chain"
  (assert (eq? 41 (-> 3 inc (times 10) inc)))
  (assert (eq? 3 (-> 3)))
  (define f (chain inc (lambda (x) (* x 2)) (chain inc inc)))
  (assert (eq? 6 (f 1)))
  (assert (eq? 6 ((chain inc) 5)))
  (define scale (fn (x) (define k 3) (* x k)))
  (assert (eq? 11 ((chain scale inc inc) 3))))

;; & collects the extra arguments into a list
(deftest "lambda: rest parameter"
  (define f (lambda (a & more) (list a more)))
  (assert (eq? 1 (first (f 1))))
  (assert (equal? '(2 3) (first (rest (f 1 2 3)))))
  (assert (equal? '() (first (rest (f 1)))))
  (assert (eq? 4 ((lambda (x y & r) (+ x y (len r))) 1 2 3)))
  (assert (equal? '(5 7) (map '(1 2) '(3 4) (lambda (a & r) (+ a (first r) 1)))))
  (assert (eq? 4 ((lambda (& all) (len all)) 1 2 3 4))))

;; ` quotes with holes: ~e inserts the value of e, ~@e the items of the list e
(deftest "macros: quasiquote"
  (define x 5)
  (define ys '(1 2))
  (assert (equal? '(5) `(~x)))
  (assert (eq? 5 (first `(~x b))))
  (assert (equal? '(a 1 2 b) `(a ~@ys b)))
  (assert (equal? '() `()))
  (define nested `(a (b ~x) ~@ys))
  (assert (eq? 4 (len nested)))
  (assert (equal? '(b 5) (first (rest nested)))))

;; defmacro: name, parameters bound to the parts of the form, & collects the rest; other forms are left alone
(defmacro do-twice (x) `(begin ~x ~x))
(defmacro my-or (a & more) `(if ~a ~a ~(if (eq? (len more) 0) #f (cons 'my-or more))))
(defmacro nothing () 7)
(deftest "macros: defmacro"
  (define n 0)
  (do-twice (set! n (+ n 1)))
  (assert (eq? 2 n))
  (assert (eq? 3 (my-or 0 "" 3)))
  (assert (eq? #f (my-or 0 0)))
  (assert (eq? 7 (nothing)))
  (assert (eq? 5 (begin 1 5))))

;; examples/autograd.lisp: (val ...) is Python's arithmetic on values, with the same graph
(load "examples/autograd.lisp")
(defn close? (x y) (< (- x y) 0.000001))
(deftest "macros: val infix"
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

;; a test name is a string (it may have spaces) or a plain symbol; both are kept as plain strings
(deftest registered-under-a-symbol-name
  (assert (eq? 1 1)))
(defn registered (name) (len (filter *TESTS* (lambda (test) (eq? (first test) name)))))
(deftest "registered: names are plain strings"
  (assert (eq? 1 (registered "eq?: zero is zero")))
  (assert (eq? 1 (registered "registered-under-a-symbol-name")))
  (assert (eq? 1 (registered "registered: names are plain strings")))
  (assert (eq? 0 (registered "no such test"))))

(deftest "numbers: mod, abs, min and max are native"
  (assert (eq? (mod 7 3) 1))
  (assert (eq? (mod -1 5) 4))
  (assert (eq? (mod 7 -3) -2))
  (assert (eq? (abs -2.5) 2.5))
  (assert (eq? (min 3 1 2) 1))
  (assert (eq? (max 3 1 2) 3))
  (assert (eq? (min '(4 2 9)) 2))
  (assert (eq? (max '(4 2 9)) 9))
  (assert (eq? (max 5) 5)))

(deftest "&&, ||: short-circuit and return the deciding operand"
  (define hits 0)
  (defn hit (x) (begin (set! hits (+ hits 1)) x))
  (assert (eq? (&& 0 (hit 1)) 0))
  (assert (eq? (|| 5 (hit 1)) 5))
  (assert (eq? hits 0))
  (assert (eq? (&& 1 2 3) 3))
  (assert (eq? (&& 1 0 (hit 3)) 0))
  (assert (eq? (|| 0 "" 7) 7))
  (assert (eq? (|| 0 nil) nil))
  (assert (eq? (&&) nil))
  (assert (eq? (reduce '(1 2 0) && 1) 0))
  (assert (eq? hits 0)))

(deftest "each: map without a result list"
  (define sum 0)
  (assert (eq? (each '(1 2 3) (lambda (x) (set! sum (+ sum x)))) nil))
  (assert (eq? sum 6))
  (each '(1 2) '(10 20) (lambda (a b) (set! sum (+ sum (* a b)))))
  (assert (eq? sum 56))
  (assert (eq? (each '() (lambda (x) x)) nil)))

(deftest "primitives: calls computed in place keep the general behaviour"
  (define a 7)
  (define l '(10 20 30))
  (defn add (x y) (+ x y))
  (defn at-of (v i) (at v i))
  (assert (eq? (add 1 2) 3))
  (assert (eq? (add "a" "b") "ab"))
  (assert (eq? (add 1 "b") "1b"))
  (assert (eq? (at-of l 1) 20))
  (assert (eq? (at-of l 5) nil))
  (assert (eq? (at-of l -1) nil))
  (assert (eq? (at-of nil 0) nil))
  (assert (eq? ((lambda (+) (+ 1 2)) (lambda (x y) (* x y))) 2))
  (assert (eq? (add 1 2) 3))
  (assert (eq? (- a 2) 5))
  (assert (eq? (mod -1 5) 4))
  (assert (eq? (eq? a 7) #t))
  (assert (eq? (eq? "x" "x") #t))
  (assert (eq? (< 1 "x") #f))
  (define sub (lambda (p q) (- p q)))
  (define old-minus -)
  (define - (lambda (p q) 100))
  (assert (eq? (sub 5 1) 100))
  (define - old-minus)
  (assert (eq? (sub 5 1) 4)))

(deftest "primitives: nested and one-operand calls in place"
  (define x 3)
  (define y 4)
  (define l '(1 2 3))
  (assert (eq? (sqrt (+ (* x x) (* y y))) 5))
  (assert (eq? (- (* (+ x 1) (+ y 1)) (mod (+ x y) 4)) 17))
  (assert (eq? (at l (- (at l 2) 1)) 3))
  (assert (eq? (not (< x y)) #f))
  (assert (eq? (not (at l 7)) #t))
  (assert (eq? (abs (- x y)) 1))
  (assert (eq? (floor (/ 7 2)) 3))
  (assert (eq? (+ (+ (+ (+ (+ x 1) 1) 1) 1) 1) 8))
  (assert (eq? (+ (at l 0) (+ (at l 1) (+ (at l 2) (+ x y)))) 13)))

(deftest "loops: closures made in a loop body keep their scopes"
  (defn churn (n) (if (> n 0) (churn (- n 1)) n))
  (defn make-adders (base)
    (define local (* base 10))
    (for/list (x (range 4))
      (define y (+ x local))
      (lambda (z) (+ x y z base))))
  (defn nested (k)
    (define out (list 0))
    (for (i (range 3))
      (define a (* i k))
      (for (j (range 3))
        (define b (+ a j))
        (vset! out 0 (concat (at out 0) (list (lambda () (+ a b i j k)))))))
    (at out 0))
  (define adders (make-adders 2))
  (churn 1000)
  (define fs (nested 5))
  (churn 1000)
  (assert (equal? (for/list (f adders) (f 100)) (list 122 124 126 128)))
  (assert (equal? (for/list (f fs) (f)) (list 5 7 9 16 18 20 27 29 31)))
  (assert (eq? (((lambda (map) (map 1 (lambda (x) (+ x 1)))) (lambda (a f) (lambda () (f a))))) 2))
  (define saved nil)
  (define each2 each)
  (define each (lambda (l f) (set! saved f)))
  (defn grab (q) (each '(1) (lambda (u) (+ q u))))
  (grab 41)
  (define each each2)
  (churn 1000)
  (assert (eq? (saved 1) 42)))

(defn counter-from (start)
  (define n start)
  (lambda () (begin (set! n (+ n 1)) n)))
(defn sum-to (n)
  (define total 0)
  (for (i (range n))
    (for (j (range 3))
      (set! total (+ total (* i j)))))
  total)
(defn shadow-param (x)
  (define f (lambda (x) (+ x 1)))
  (list (f 10) x))
(defn fact-acc (n) (if (< n 2) 1 (* n (fact-acc (- n 1)))))
(defn deep (n) (if (eq? n 0) 0 (+ 1 (deep (- n 1)))))
(defn boom (x) (begin (define y (+ x 1)) (error "boom") y))
(defn uses-minus (a b) (- a b))
(deftest "tier 2: compiled function bodies behave like the tree evaluator"
  (define c1 (counter-from 10))
  (define c2 (counter-from 100))
  (c1)
  (c2)
  (assert (equal? (list (c1) (c2)) (list 12 102)))
  (assert (eq? (sum-to 10) 135))
  (assert (equal? (shadow-param 5) (list 11 5)))
  (assert (eq? (fact-acc 10) 3628800))
  (assert (eq? (deep 100000) 100000))
  (assert (equal? (try (lambda () (boom 1)) (lambda (e) "caught")) "caught"))
  (assert (eq? (uses-minus 5 3) 2))
  (assert (eq? (uses-minus 5 3) 2)))

(define later-name 100)
(defn closure-before-define ()
  (define f (lambda () later-name))
  (define before (f))
  (define later-name 5)
  (list before (f)))
(defmacro tier-mm () 1)
(defn use-tier-mm () (tier-mm))
(defn rest-tier (a & more) (list a more))
(defn mut-param (a) (begin (set! a (+ a 1)) (define b (* a 2)) (list a b)))
(define use-tier-first (use-tier-mm))
(defmacro tier-mm () 2)
(deftest "tier 2: names, macros and arguments"
  (assert (equal? (closure-before-define) (list 100 5)))
  (assert (eq? use-tier-first 1))
  (assert (eq? (use-tier-mm) 2))
  (assert (equal? (rest-tier 1 2 3) (list 1 (list 2 3))))
  (assert (equal? (rest-tier 1) (list 1 (list))))
  (assert (equal? (mut-param 5) (list 6 12))))

(defn store (l i x) (vset! l i x))
(defn store-twice (l) (begin (vset! l 0 (vset! l 1 9)) l))
(deftest "tier 2: vset! in a compiled function"
  (define l (list 1 2 3))
  (assert (eq? (store l 1 20) 20))
  (assert (equal? l (list 1 20 3)))
  (assert (equal? (store-twice l) (list 9 9 3)))
  (assert (equal? (try (lambda () (store l 3 0)) (lambda (e) "range")) "range"))
  (assert (equal? (try (lambda () (store nil 0 0)) (lambda (e) "list")) "list"))
  (assert (equal? l (list 9 9 3))))

(defn count-up (n acc) (if (eq? n 0) acc (count-up (- n 1) (+ acc 1))))
(defn collect-closures (n acc)
  (begin
    (define tmp (+ n 100))
    (if (eq? n 0) acc (collect-closures (- n 1) (concat acc (list (lambda () tmp)))))))
(defn defines-reset (n seen)
  (begin
    (define fresh (if (eq? n 3) 1 2))
    (if (eq? n 0) seen (defines-reset (- n 1) (concat seen (list fresh))))))
(defn fewer-args (a b) (if (eq? a 0) b (fewer-args (- a 1))))
(deftest "tier 2: a function calling itself in tail position"
  (assert (eq? (count-up 1000000 0) 1000000))
  (assert (equal? (for/list (f (collect-closures 3 (list))) (f)) (list 103 102 101)))
  (assert (equal? (defines-reset 3 (list)) (list 1 2 2)))
  (assert (eq? (fewer-args 3 5) nil)))

(define cond-name 100)
(defn define-in-branch (flag)
  (if flag
    (begin (define cond-name 5) (+ cond-name 1))
    cond-name))
(defn define-then-use-outside (flag)
  (begin
    (if flag (define cond-name 7) 0)
    cond-name))
(defn branch-total (n)
  (if (eq? n 0) 0
    (begin
      (define total 0)
      (for (i (range n)) (set! total (+ total i)))
      total)))
(deftest "tier 2: defines inside a branch"
  (assert (eq? (define-in-branch 1) 6))
  (assert (eq? (define-in-branch 0) 100))
  (assert (eq? (define-then-use-outside 1) 7))
  (assert (eq? (define-then-use-outside 0) 100))
  (assert (eq? (branch-total 5) 10))
  (assert (eq? (branch-total 0) 0)))

(defn squares (n) (for/list (i (range n)) (* i i)))
(defn table (n) (for/list (i (range n)) (for/list (j (range n)) (+ (* i 10) j))))
(defn adders (n) (for/list (i (range n)) (lambda (x) (+ x i))))
(defn calls-out (xs) (for/list (x xs) (+ (len (list x x)) (len (squares x)))))
(defn sum-with-effects (xs)
  (define s 0)
  (define seen (list 0))
  (for (x xs)
    (set! s (+ s x))
    (vset! seen 0 (+ (at seen 0) 1)))
  (list s (at seen 0)))
(defn failing-loop (xs) (for/list (x xs) (if (eq? x 2) (error "bad") x)))
(defn nested-return (n) (for/list (i (range n)) (if (eq? i 1) (for/list (j (range 2)) j) i)))
(deftest "tier 2: loops run by the bytecode"
  (assert (equal? (squares 5) (list 0 1 4 9 16)))
  (assert (equal? (squares 0) (list)))
  (assert (equal? (table 3) (list (list 0 1 2) (list 10 11 12) (list 20 21 22))))
  (assert (equal? (for/list (f (adders 3)) (f 100)) (list 100 101 102)))
  (assert (equal? (sum-with-effects (list 1 2 3 4)) (list 10 4)))
  (assert (equal? (sum-with-effects (list)) (list 0 0)))
  (assert (equal? (try (lambda () (failing-loop (list 1 2 3))) (lambda (e) "caught")) "caught"))
  (assert (equal? (failing-loop (list 1 3)) (list 1 3)))
  (assert (equal? (nested-return 3) (list 0 (list 0 1) 2)))
  (assert (equal? (calls-out (list 1)) (list 3)))
  (assert (equal? (squares 100000) (squares 100000))))

(defn arith-ops (a b) (list (mod a b) (/ a b) (not a) (not (< a b)) (- a b) (* a b)))
(deftest "tier 2: mod, / and not in a compiled function"
  (assert (equal? (arith-ops 7 2) (list 1 3.5 #f #t 5 14)))
  (assert (equal? (arith-ops -1 5) (list 4 -0.2 #f #f -6 -5)))
  (assert (equal? (arith-ops 0 3) (list 0 0 #t #f -3 0)))
  (assert (eq? (/ 1 0) (/ 1 0)))
  (assert (eq? (len (arith-ops "x" 2)) 6))) ; text is not a number: the arithmetic gives nan, like the tree evaluator

(define inl-counter 100)
(defn inl-read-counter () inl-counter)
(defn inl-bump (n) (begin (set! inl-counter (+ inl-counter n)) inl-counter))
(defn inl-with-def (x) (begin (define y (* x 2)) (+ y 1)))
(defn inl-caller (inl-counter) (list (inl-read-counter) inl-counter (inl-with-def inl-counter) (inl-bump 5)))
(defn inl-inc (x) (+ x 1))
(defn inl-use (n) (+ (inl-inc n) (inl-inc (inl-inc n))))
(defn inl-clash (x y) (list (inl-with-def y) x y))
(defn inl-a (n acc) (if (eq? n 0) acc (inl-b n acc)))
(defn inl-b (n acc) (inl-a (- n 1) (+ acc 1)))
(define inl-first (inl-use 10))
(defn inl-inc (x) (+ x 1000))
(deftest "tier 2: small functions inlined into their callers"
  (assert (equal? (inl-caller 7) (list 100 7 15 105)))
  (assert (eq? inl-counter 105))
  (assert (eq? inl-first 23))
  (assert (eq? (inl-use 10) 3020))
  (assert (equal? (inl-clash 1 2) (list 5 1 2)))
  (assert (eq? (inl-a 1000000 0) 1000000)))

(define cx-each (partial (lambda (l f) f) '()))
(define each-saved each)
(define each cx-each)
(define cx-maker
  (lambda (x)
    (each '(1)
      (lambda (u)
        (begin
          (define before (+ x u))
          (define x 5)
          before)))))
(define cx-saved (cx-maker 41))
(define each each-saved)
((lambda (z) z) 999)
(define cx-map each)
(define cx-file-x9 "/tmp/tinylisp-spec-x9.lisp")
(define cx-file-x20 "/tmp/tinylisp-spec-x20.lisp")
(write-file cx-file-x9 "(define x 9)")
(write-file cx-file-x20 "(define x 20)")
(define cx-load-helper (lambda () (load cx-file-x9)))
(deftest "review: names that merely look like the loop natives, load in compiled code, duplicate parameters"
  (assert (eq? (cx-saved 1) 42))
  (assert (eq? ((lambda () (cx-map '(1 2) (lambda (x) x)))) nil))
  (assert (eq? ((lambda (x) (begin (cx-load-helper) x)) 1) 1))
  (assert (eq? ((lambda (x)
                  ((lambda ()
                     (begin
                       (define g (lambda () x))
                       (g)
                       (load cx-file-x20)
                       (g)))))
                10)
               20))
  (assert (eq? ((lambda (x x) x) 1 2) 2)))

(defn count-loop (n) (for/list (i (range n)) (* i 2)))
(defn count-each (n) (begin (define s 0) (for (i (range n)) (set! s (+ s i))) s))
(defn count-with-range-arg (n) (for/list (i (range (+ n 1))) i))
(defn count-shadowed (range) (for/list (i (range 3)) i))
(deftest "tier 2: loops over (range n) count"
  (assert (equal? (count-loop 3) (list 0 2 4)))
  (assert (equal? (count-loop 0) (list)))
  (assert (equal? (count-loop -2) (list)))
  (assert (equal? (count-loop 2.7) (list 0 2)))
  (assert (equal? (count-loop "x") (list)))
  (assert (equal? (count-loop nil) (list)))
  (assert (eq? (count-each 100) 4950))
  (assert (equal? (count-with-range-arg 2) (list 0 1 2)))
  (assert (equal? (count-shadowed (lambda (n) (list 7 8))) (list 7 8))))

(defn store-ll (l i) (vset! l i (+ i 100)))
(defn mixed (l i) (list (+ (at l i) 1) (< (at l i) 3) (eq? (at l i) 2) (- (at l i) i) (* (at l i) 2)))
(defn mixed-k (x) (list (+ x 1) (- x 1) (* x 2) (< x 2) (>= x 2) (eq? x 2) (at x 0)))
(deftest "tier 2: operands taken from a local or a constant"
  (define l (list 1 2 3))
  (assert (eq? (store-ll l 1) 101))
  (assert (equal? l (list 1 101 3)))
  (assert (equal? (try (lambda () (store-ll l 5)) (lambda (e) "range")) "range"))
  (assert (equal? (try (lambda () (store-ll nil 0)) (lambda (e) "list")) "list"))
  (assert (equal? (mixed (list 1 2 3) 1) (list 3 #t #t 1 4)))
  (assert (equal? (mixed (list 1 2 3) 5) (list 1 #t #f -5 0)))
  (assert (equal? (mixed-k 2) (list 3 1 4 #f #t #t nil)))
  (assert (equal? (at (mixed-k "a") 0) "a1"))
  (assert (equal? (at (mixed-k "a") 3) #f))
  (assert (equal? (at (mixed-k "a") 4) #f)))

(write-file "/tmp/tinylisp-spec-x9b.lisp" "(define x 9)")
(define cx-call-arg (lambda (f) (f "/tmp/tinylisp-spec-x9b.lisp")))
(deftest "review: a helper that calls a function it is given is not inlined"
  (assert (eq? ((lambda (x) (begin (cx-call-arg load) x)) 1) 1)))

(run-tests)
