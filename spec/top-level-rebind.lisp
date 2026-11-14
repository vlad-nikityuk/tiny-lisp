(define save-each each)
(define +save +)

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

(run-tests)