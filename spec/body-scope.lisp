;; The scoping rules of function bodies.
;; A body's local names are its parameters and every name defined anywhere in it (not inside a nested lambda); a defined name is
;; local to the whole body and unbound until its define runs, and reading it while unbound is an error.

(define unbound-x "TinyLisp: x is used before it is defined")
(defn message-of (thunk) (try thunk (lambda (e) e)))

(defn defined-in-branch (flag) (if flag (define x 2) 0) x)
(deftest "body: a name defined in a branch that ran can be read"
  (assert (eq? 2 (defined-in-branch #t))))
(deftest "body: a name defined in a branch that did not run is an error"
  (assert (eq? unbound-x (message-of (lambda () (defined-in-branch #f))))))

(define x 100)
(defn read-then-define () (define before x) (define x 5) before)
(deftest "body: a define later in the body makes the name local, the global is not read"
  (assert (eq? unbound-x (message-of read-then-define)))
  (assert (eq? x 100)))

(defn define-in-and (flag) (&& flag (define x 3)) x)
(defn define-in-argument () (list (define x 4) x))
(defn define-in-nested-begin () (if #t (begin (begin (define x 6))) 0) x)
(deftest "body: defines inside && operands, call arguments and nested begins count"
  (assert (eq? 3 (define-in-and #t)))
  (assert (eq? unbound-x (message-of (lambda () (define-in-and #f)))))
  (assert (equal? (list 4 4) (define-in-argument)))
  (assert (eq? 6 (define-in-nested-begin))))

(defn param-never-unbound (a) (define b (+ a 1)) (list a b))
(defn param-defined-again (a) (define a (+ a 1)) a)
(deftest "body: parameters are bound from the start"
  (assert (equal? (list 1 2) (param-never-unbound 1)))
  (assert (eq? 2 (param-defined-again 1))))

;; closures
(define later-closure-x 7)
(defn closure-too-early ()
  (define f (lambda () later-closure-x))
  (define early (try f (lambda (e) e)))
  (define later-closure-x 5)
  (list early (f)))
(deftest "body: a closure reading a captured name before its define ran is an error"
  (assert (equal? (list "TinyLisp: later-closure-x is used before it is defined" 5) (closure-too-early))))

(defn local-helpers ()
  (define even? (lambda (n) (if (eq? n 0) #t (odd? (- n 1)))))
  (define odd? (lambda (n) (if (eq? n 0) #f (even? (- n 1)))))
  (list (even? 10) (odd? 7) (even? 7)))
(deftest "body: local helper functions may call each other"
  (assert (equal? (list #t #t #f) (local-helpers))))

;; loops: each iteration starts with its defines unbound
(defn loop-restart ()
  (define seen '())
  (for (i (range 3))
    (if (eq? i 0) (define y 10) 0)
    (set! seen (cons y seen)))
  seen)
(defn loop-fresh ()
  (define sums '())
  (for (i (range 3))
    (define y (* i 10))
    (set! sums (cons y sums)))
  sums)
(deftest "body: a loop body's define starts unbound in every iteration"
  (assert (eq? "TinyLisp: y is used before it is defined" (message-of loop-restart)))
  (assert (equal? (list 20 10 0) (loop-fresh))))

;; a self tail call starts again with unbound defines
(defn tail-restart (n flag)
  (if (eq? n 0) (if flag y 0)
    (begin
      (if (eq? n 2) (define y 1) 0)
      (tail-restart (- n 1) #t))))
(deftest "body: a self tail call starts with unbound defines"
  (assert (eq? "TinyLisp: y is used before it is defined" (message-of (lambda () (tail-restart 3 #f))))))

;; an inlined small function: its defines are unbound too
(defn inl-define (flag) (if flag (define z 1) 0) z)
(defn inl-caller (flag) (+ 1 (inl-define flag)))
(deftest "body: the defines of an inlined function are unbound at each call"
  (assert (eq? 2 (inl-caller #t)))
  (assert (eq? "TinyLisp: z is used before it is defined" (message-of (lambda () (inl-caller #f)))))
  (assert (eq? 2 (inl-caller #t))))

;; set!
(define set-global 1)
(defn set-existing-global () (set! set-global 2))
(defn set-unbound-local () (set! w 4) (define w (+ w 1)) w)
(defn set-unknown () (set! never-defined-anywhere 1))
(defn set-unknown-in-closure () ((lambda () (set! never-defined-anywhere 1))))
(deftest "set!: an existing global is assigned"
  (set-existing-global)
  (assert (eq? 2 set-global)))
(deftest "set!: a local whose slot is unbound is assigned"
  (assert (eq? 5 (set-unbound-local))))
(deftest "set!: a name that exists nowhere is an error"
  (assert (eq? "TinyLisp: set!: never-defined-anywhere is not defined" (message-of set-unknown)))
  (assert (eq? "TinyLisp: set!: never-defined-anywhere is not defined" (message-of set-unknown-in-closure)))
  (assert (eq? "TinyLisp: set!: never-defined-anywhere is not defined" (message-of (lambda () (eval '(set! never-defined-anywhere 1)))))))

;; load and eval run at top level
(define from-file 0)
(write-file "/tmp/tinylisp-spec-scope.lisp" "(define from-file 9) (define from-file-new 1)")
(defn load-in-function () (define from-file 1) (define keep 2) (load "/tmp/tinylisp-spec-scope.lisp") (list from-file keep))
(defn eval-in-function () (define x 1) (eval '(define x 8)) x)
(deftest "load and eval: run in the global scope, the caller's locals stay"
  (assert (equal? (list 1 2) (load-in-function)))
  (assert (eq? 9 from-file))
  (assert (eq? 1 from-file-new))
  (assert (eq? 1 (eval-in-function)))
  (assert (eq? 8 x)))

;; evaluation order: a define in an argument is visible to the arguments after it, not before
(defn order-forward () (list (define a 1) (+ a 1)))
(defn order-reverse () (list a (define a 1)))
(defn self-initializer () (define x (+ x 1)) x)
(defn or-define (flag) (|| flag (define v 5)) v)
(deftest "body: evaluation order decides what a define in an argument or initializer can see"
  (assert (equal? (list 1 2) (order-forward)))
  (assert (eq? "TinyLisp: a is used before it is defined" (message-of order-reverse)))
  (assert (eq? unbound-x (message-of self-initializer))))
(deftest "body: a define in a later operand of || is certain only if the operand ran"
  (assert (eq? 5 (or-define #f)))
  (assert (eq? "TinyLisp: v is used before it is defined" (message-of (lambda () (or-define #t))))))

;; the operands of vset! are checked reads too
(defn vset-both (flag) (if flag (begin (define l (list 1 2)) (define i 0)) 0) (vset! l i 9) l)
(defn vset-index (flag) (define l (list 1 2)) (if flag (define i 1) 0) (vset! l i 9) l)
(deftest "body: the list and the index of vset! may be unbound"
  (assert (equal? (list 9 2) (vset-both #t)))
  (assert (eq? "TinyLisp: l is used before it is defined" (message-of (lambda () (vset-both #f)))))
  (assert (equal? (list 1 9) (vset-index #t)))
  (assert (eq? "TinyLisp: i is used before it is defined" (message-of (lambda () (vset-index #f))))))

;; a closure's remembered lookup of a captured name is still checked when the name is unbound in a later scope
(defn warm-then-unbound ()
  (define results '())
  (for (i (range 2))
    (define g (lambda () cap))
    (if (eq? i 0) (define cap 7) 0)
    (set! results (cons (try g (lambda (e) e)) results)))
  results)
(deftest "body: a warmed outer lookup still raises when the captured name is unbound"
  (assert (equal? (list "TinyLisp: cap is used before it is defined" 7) (warm-then-unbound))))

;; code compiled with a global primitive is compiled again when a function first defines that name locally
(defn warm-plus () (+ 1 2))
(warm-plus) ; compiled with the primitive as an instruction
(defn local-plus-later ()
  (define f (lambda () (+ 1 2)))
  (define + (lambda (a b) 99))
  (list (f) (warm-plus)))
(deftest "body: defining a primitive's name locally makes the closures of the function see it"
  (assert (equal? '(99 3) (local-plus-later))))

(deftest "body: deep recursion and deep data are fine with checked reads"
  (defn count-down (n) (if (eq? n 0) 0 (begin (define r (count-down (- n 1))) (+ r 1))))
  (assert (eq? 100000 (count-down 100000))))

(run-tests)
