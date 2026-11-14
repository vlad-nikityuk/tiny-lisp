;; call-with-current-continuation: escape, re-entry, and stack interactions.

(deftest "call/cc: normal return"
  (assert (equal? (+ 1 (call/cc (lambda (k) 2))) 3)))

(deftest "call/cc: escape"
  (assert (equal? (call/cc (lambda (k) (k 5))) 5))
  (assert (equal? (+ 1 (call/cc (lambda (k) (k 5)))) 6)))

(deftest "call/cc: zero arguments to k is nil"
  (assert (equal? (call/cc (lambda (k) (k))) nil)))

(deftest "call/cc: generator re-entry"
  (define n 0)
  (define k #f)
  (define bump (lambda () (set! n (+ n 1)) (k n)))
  (call/cc (lambda (c) (begin (set! k c) 0)))
  (assert (equal? (bump) 1))
  (assert (equal? (bump) 2))
  (assert (equal? (bump) 3)))

(deftest "call/cc: map callback"
  (assert (equal? (car (map (list 1) (lambda (x) (call/cc (lambda (k) (k (+ x 10))))))) 11)))

(deftest "call/cc: nested"
  (assert (equal? (call/cc (lambda (k1) (call/cc (lambda (k2) (k1 (k2 3)))))) 3)))

(deftest "call/cc: tail escape"
  (assert (equal? (call/cc (lambda (k) (k 4))) 4)))

(deftest "call/cc: deep capture"
  (define go (lambda (n k) (if (eq? n 0) (k 0) (go (- n 1) k))))
  (assert (equal? (call/cc (lambda (k) (go 200 k))) 0)))

(deftest "call/cc: non-function"
  (assert (equal? "TinyLisp: call-with-current-continuation needs a function"
                  (try (lambda () (call/cc 1)) (lambda (e) e)))))

(deftest "call/cc: too many values to k"
  (assert (equal? "TinyLisp: a continuation takes one value"
                  (try (lambda () (call/cc (lambda (k) (k 1 2))))
                       (lambda (e) e)))))

(run-tests)