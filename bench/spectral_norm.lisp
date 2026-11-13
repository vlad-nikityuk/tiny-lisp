; Spectral norm of the infinite matrix A[i][j] = 1 / ((i + j) (i + j + 1) / 2 + i + 1), power method, from the
; Computer Language Benchmarks Game.
(load "bench/prelude.lisp")

(defn eval-A (i j)
  (/ 1.0 (+ (floor (/ (* (+ i j) (+ i j 1)) 2)) i 1)))

(defn times-u (u)
  (define n (len u))
  (for/list (i (range n))
    (sum (for/list (j (range n)) (* (eval-A i j) (at u j))))))

(defn times-u-transposed (u)
  (define n (len u))
  (for/list (i (range n))
    (sum (for/list (j (range n)) (* (eval-A j i) (at u j))))))

(defn times-AtA (u)
  (times-u-transposed (times-u u)))

(define n 250)
(define u (for/list (_ (range n)) 1.0))
(define v (zeros n))
(for (_ (range 10))
  (set! v (times-AtA u))
  (set! u (times-AtA v)))
(define vBv (sum (for/list ((ui vi) (zip u v)) (* ui vi))))
(define vv (sum (for/list (vi v) (* vi vi))))
(print (floor (* (sqrt (/ vBv vv)) 1000000000)))
