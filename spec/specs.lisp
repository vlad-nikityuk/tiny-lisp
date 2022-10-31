;; deftest
;; 1. unfolds to (define (lambda ... ))
;; 2. adds itself to *TESTS* test list
;; 3. Adds expr: and test: to assert call


;; eq? tests
;; (deftest eq?--zero-is-zero
;;   (assert (eq? 0 0)))

;; (deftest eq?--nil-is-nil
;;   (assert (eq? nil nil)))

;; (deftest eq?--empty-list-is-nil
;;   (assert (eq? nil '()) ))


;; ;; empty?
;; (deftest empty?--true
;;   (begin
;;    (define res (empty? '()))
;;    (assert (eq? #t res))))

;; (deftest empty?--false
;;   (begin
;;    (define res (empty? '(1 2)))
;;    (assert (eq? #f res))))


;; ;; list?
;; (deftest list?-empty
;;   (begin
;;    (define res (list? '()))
;;    (assert (eq? #t res))))

;; (deftest list?-with-elements
;;   (begin
;;    (define res (list? '(1 2 3)))
;;    (assert (eq? #t res))))

;; (deftest list?-non-list
;;   (begin
;;    (define res (list? 1))
;;    (assert (eq? #f res))))

;; (deftest concat-arrays
;;   (begin
;;    (define res (concat '(4 5 6) '(1 2 3)))
;;    (assert (equal? '(4 5 6 1 2 3) res))))

;; (deftest equality
;;   (begin
;;     (assert (eq? #t #t)
;;     (assert (eq? 4 4)))))

;; (deftest first-returns-head-of-list
;;   (begin
;;    (define lst '(4 5 6))
;;    (define fst (first lst))
;;    (assert (eq? fst 4)))
;; )

;; (deftest begin-should-return-last-expr
;;   (assert (eq? 4 (begin 1 2 3 4))))

;; (deftest assert-fails-on-false-expr
;;   (if
;;     (eq?
;;       (try
;;         (lambda () (begin (assert #f) #f))
;;         (lambda (e) #t))
;;       #t)
;;     (pass)
;;     (error 'oh-dear)))

;; (deftest at-returns-by-idx
;;   (begin
;;    (define lst '(4 5 6))
;;    (assert (eq? (at lst 0) 4))
;;    (assert (eq? (at lst 1) 5))
;;    (assert (eq? (at lst 2) 6))
;;   ))

;; (deftest partial-functions
;;   (begin
;;     (defn add (a b)
;;       (+ a b))
;;     (define add-one (partial add '(1) ))
;;     (define two (add-one 1))
;;     (assert (eq? two 2))))

;; (defrec sum-below (x sum)
;;  (if (eq? x 0)
;;    sum
;;    (sum-below (- x 1) (+ sum x))))

;; (deftest trampoline-rec
;;  (assert (eq? 6 (sum-below 3 0))))

;; (deftest trampoline-rec-big
;;  (assert (eq? 5000050000 (sum-below 100000 0))))

;; (run-tests)
