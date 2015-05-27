;; deftest
;; 1. unfolds to (define (lambda ... ))
;; 2. adds itself to *GLOBAL* test list
;; 3. Adds expr: and test: to assert call

(deftest zero-is-zero
  (assert (eq? 0 0)))

(deftest nil-should-be-nil
  (begin
   (define nil-is-nil (eq? nil nil))
   (assert (eq? nil-is-nil #t))))

(deftest emplty-list-is-nil
  (assert (eq? nil (quote ()))))

(deftest failing-test
  (assert (eq? #f #t)))

(run-tests)

