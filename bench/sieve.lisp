; The sieve of Eratosthenes up to 2500000: how many primes, and their sum.
(load "bench/prelude.lisp")

(define n 2500000)
(define is-prime (for/list (_ (range (+ n 1))) 1))
(vset! is-prime 0 0)
(vset! is-prime 1 0)
(defn sieve (i)
  (if (<= (* i i) n)
    (begin
      (if (at is-prime i)
        (for (j (range-step (* i i) (+ n 1) i))
          (vset! is-prime j 0)))
      (sieve (+ i 1)))))
(sieve 2)
(define count 0)
(define total 0)
(for (k (range (+ n 1)))
  (if (at is-prime k)
    (begin
      (+= count 1)
      (+= total k))))
(print count total)
