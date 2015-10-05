;; deftest
;; 1. unfolds to (define (lambda ... ))
;; 2. adds itself to *TESTS* test list
;; 3. Adds expr: and test: to assert call


;; eq? tests
(deftest eq?-zero-is-zero
  (assert (eq? 0 0)))

(deftest eq?-nil-is-nil
  (assert (eq? nil nil)))

(deftest eq?-empty-list-is-nil
  (assert (eq? nil '())))

;;(deftest failing-test
;;  (assert (eq? #f #t)))

(run-tests)

;; (it (quote nil-should-be-nil) (lambda ()))
