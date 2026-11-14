(define save-each each)
(define +save +)
(define map-save map)
(define range-save range)

(defmacro rebind-plus-99 ()
  '(define + (lambda (a b) 99)))

(defn rebind-plus-99! ()
  (set! + (lambda (a b) 99)))

(defn function-body-loop-rebind-demo ()
  (define a (for/list (i (list 1)) (+ i 0)))
  (rebind-plus-99!)
  (define b (for/list (i (list 1)) (+ i 0)))
  (define c (+ 0 1))
  (list a b c))

(defn function-body-loop-in-list-operand-demo ()
  (for/list (i (begin (rebind-plus-99!) (list 1 2))) (+ i 0)))

(deftest "vm: top-level loop body uses a rebound + from define in the same form"
  (assert (eq? #t (eval '(begin (define + (lambda (a b) 99)) (equal? (list 99 99) (for/list (i (list 1 2)) (+ i 0)))))))
  (set! + +save))

(deftest "vm: top-level loop body uses a rebound + from set! in the same form"
  (assert (eq? #t (eval '(begin (set! + (lambda (a b) 99)) (equal? (list 99 99) (for/list (i (list 1 2)) (+ i 0)))))))
  (set! + +save))

(deftest "vm: top-level loop body uses a rebound + from a macro in the same form"
  (assert (eq? #t (eval '(begin (rebind-plus-99) (equal? (list 99 99) (for/list (i (list 1 2)) (+ i 0)))))))
  (set! + +save))

(deftest "vm: top-level loop body honors a rebound vset! in the same form"
  (assert (eq? #t (eval '(begin (define vset! (lambda (a b c) "no")) (define l (list 1 2)) (for (x (list 0)) (vset! l 0 9)) (equal? (list 1 2) l))))))

(deftest "vm: top-level loop body honors a rebound each in the same form"
  (assert (eq? #t (eval '(begin (define each (lambda (l f) "no")) (equal? (list "no") (for/list (x (list 1)) (each (list 2) (lambda (y) y))))))))
  (set! each save-each))

(deftest "vm: top-level loop body sees a rebound range in the same form"
  (assert (eq? #t (eval '(begin (set! range (lambda (n) (list 7))) (equal? (list 7) (for/list (i (list 1)) (first (range 3))))))))
  (set! range range-save))

(deftest "vm: top-level counted loops re-check range between two loops in one form"
  (assert (eq? #t (eval '(begin (define r1 (for/list (i (range 3)) i)) (set! range (lambda (n) (list 7))) (define r2 (for/list (i (range 3)) i)) (equal? (list (list 0 1 2) (list 7)) (list r1 r2))))))
  (set! range range-save))

(deftest "vm: top-level slow loop error then native loop in the next form"
  (assert (eq? "slow" (eval '(begin (set! each (lambda (l f) (error "slow"))) (try (lambda () (for (x (list 1)) x)) (lambda (e) e))))))
  (set! each save-each)
  (assert (eq? #t (eval '(begin (equal? (list 0 1) (for/list (i (range 2)) i)))))))

(deftest "vm: top-level counted loops honor a rebound range in the same form"
  (assert (equal? (list 7) (eval '(begin (set! range (lambda (n) (list 7))) (for/list (i (range 3)) i))))))

(deftest "vm: top-level each rebound in one thunk"
  (assert (eq? "no" (eval '(begin (define each (lambda (l f) "no")) (each (list 1) (lambda (x) x)))))))

(deftest "vm: top-level vset! rebound in one thunk"
  (assert (equal? (list "no" (list 1 2))
                  (eval '(begin (define vset! (lambda (a b c) "no")) (define l (list 1 2)) (list (vset! l 0 9) l))))))

(deftest "vm: top-level not rebound in one thunk"
  (assert (eq? "no" (eval '(begin (define not (lambda (x) "no")) (not #f))))))

(deftest "vm: top-level map rebound in one thunk"
  (assert (eq? "no" (eval '(begin (define map (lambda (l f) "no")) (map (list 1 2) (lambda (x) x)))))))

(deftest "vm: top-level + rebound in one thunk"
  (set! + +save)
  (assert (eq? 99 (eval '(begin (set! + (lambda (a b) 99)) (+ 1 2)))))
  (set! + +save))

(deftest "vm: top-level loop fallback uses the rebound each on the operand"
  (assert (eq? "rebound" (eval '(begin (set! each (lambda (l f) "rebound")) (each (begin (set! each save-each) (list 1)) (lambda (x) x)))))))

(deftest "vm: top-level loop fallback keeps native each on the operand"
  (assert (eq? nil (eval '(begin (each (begin (set! each (lambda (l f) "rebound")) (list 1)) (lambda (x) x)))))))

(deftest "vm: top-level loop fallback evaluates the list operand once"
  (assert (eq? 1 (eval '(begin (define n 0) (set! each (lambda (l f) nil)) (each (begin (set! n (+ n 1)) (list 1)) (lambda (x) x)) n)))))

(deftest "vm: top-level loop fallback evaluates a range count once"
  (assert (eq? 1 (eval '(begin (define n 0) (set! each (lambda (l f) nil)) (each (begin (set! n (+ n 1)) (range 3)) (lambda (i) i)) n)))))

(deftest "vm: function-body loop keeps + inlined in the body after set! in the same call"
  (set! + +save)
  (set! map map-save)
  (assert (equal? '((1) (1) 1) (function-body-loop-rebind-demo)))
  (set! + +save))

(deftest "vm: function-body loop keeps + inlined in the body after set! in the list operand"
  (set! + +save)
  (set! map map-save)
  (assert (equal? '(1 2) (function-body-loop-in-list-operand-demo)))
  (set! + +save))

(run-tests)

