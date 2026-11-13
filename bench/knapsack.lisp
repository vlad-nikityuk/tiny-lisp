; The 0/1 knapsack problem: 400 items, capacity 6000, one-dimensional dynamic programme.
(load "bench/prelude.lisp")

(define n 400)
(define capacity 6000)
(define weights (for/list (_ (range n)) (+ 1 (floor (* (rand) 60)))))
(define values (for/list (_ (range n)) (+ 1 (floor (* (rand) 100)))))

(define best (zeros (+ capacity 1)))
(for (i (range n))
  (for (c (range-step capacity (- (at weights i) 1) -1))
    (vset! best c (max (at best c) (+ (at best (- c (at weights i))) (at values i))))))
(print (at best capacity) (sum weights) (sum values))
