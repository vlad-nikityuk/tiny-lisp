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

(deftest first-returns-head-of-list
  (begin
   (define lst '(4 5 6))
   (define fst (first lst))
   (assert (equal? fst 4))))

(deftest rest-returns-tail-of-list-SHOULD-FAIL
  (begin
   (define lst '(4 5 6))
   (define rst (rest lst))
   (assert (equal? rst '(5 6 7 8)))))

(run-tests)
