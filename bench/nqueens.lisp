; Count the solutions of the n-queens problem by backtracking with column and diagonal flags.
(load "bench/prelude.lisp")

(defn solve (row n cols diag1 diag2)
  (if (eq? row n) 1
    (begin
      (define total 0)
      (for (c (range n))
        (if (&& (eq? (at cols c) 0) (eq? (at diag1 (+ row c)) 0) (eq? (at diag2 (+ (- row c) (- n 1))) 0))
          (begin
            (vset! cols c 1)
            (vset! diag1 (+ row c) 1)
            (vset! diag2 (+ (- row c) (- n 1)) 1)
            (+= total (solve (+ row 1) n cols diag1 diag2))
            (vset! cols c 0)
            (vset! diag1 (+ row c) 0)
            (vset! diag2 (+ (- row c) (- n 1)) 0))))
      total)))

(define n 12)
(print (solve 0 n (zeros n) (zeros (* 2 n)) (zeros (* 2 n))))
