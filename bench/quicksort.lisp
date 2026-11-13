; Quicksort of 150000 random integers, in place, with Lomuto partitioning.
(load "bench/prelude.lisp")

(defn partition (a lo hi)
  (define pivot (at a hi))
  (define i lo)
  (for (j (range-between lo hi))
    (if (< (at a j) pivot)
      (begin
        (swap! a i j)
        (+= i 1))))
  (swap! a i hi)
  i)

(defn quicksort (a lo hi)
  (if (< lo hi)
    (begin
      (define p (partition a lo hi))
      (quicksort a lo (- p 1))
      (quicksort a (+ p 1) hi))))

(define n 150000)
(define a (for/list (_ (range n)) (floor (* (rand) 1000000))))
(quicksort a 0 (- n 1))
(define ordered 1)
(define checksum 0)
(for (i (range n))
  (if (&& (> i 0) (> (at a (- i 1)) (at a i)))
    (set! ordered 0))
  (set! checksum (mod (+ checksum (* i (at a i))) 1000003)))
(print ordered checksum (at a 0) (at a (- n 1)))
