; Dijkstra's shortest paths on a 50 x 50 grid of random step costs, with the O(V^2) array version.
(load "bench/prelude.lisp")

(define w 50)
(define h 50)
(define cost (for/list (_ (range (* w h))) (+ 1 (floor (* (rand) 9)))))

(define INF 1000000000)
(define dist (for/list (_ (range (* w h))) INF))
(define done (zeros (* w h)))
(vset! dist 0 (at cost 0))
(for (_ (range (* w h)))
  (define u -1)
  (define best INF)
  (for (v (range (* w h)))
    (if (&& (eq? (at done v) 0) (< (at dist v) best))
      (begin
        (set! best (at dist v))
        (set! u v))))
  (if (not (eq? u -1))
    (begin
      (vset! done u 1)
      (define x (mod u w))
      (define y (floor (/ u w)))
      (for ((dx dy) '((1 0) (-1 0) (0 1) (0 -1)))
        (define nx (+ x dx))
        (define ny (+ y dy))
        (if (&& (<= 0 nx) (< nx w) (<= 0 ny) (< ny h))
          (begin
            (define v (+ (* ny w) nx))
            (if (< (+ (at dist u) (at cost v)) (at dist v))
              (vset! dist v (+ (at dist u) (at cost v))))))))))
(print (at dist (- (* w h) 1)) (sum dist))
