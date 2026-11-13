; Fannkuch-redux from the Computer Language Benchmarks Game: over all permutations of 0..n-1, flip the first k+1
; elements while the first element k is not 0, and count the flips. (The `while`s are tail-recursive functions.)
(load "bench/prelude.lisp")

(defn reverse-prefix (a k)
  (define i 0)
  (reverse-from a i k))
(defn reverse-from (a i k)
  (if (< i k)
    (begin
      (swap! a i k)
      (reverse-from a (+ i 1) (- k 1)))))

(defn rotate-left (a r)
  (define first (at a 0))
  (for (i (range r))
    (vset! a i (at a (+ i 1))))
  (vset! a r first))

(defn flips-of (perm flips)
  (define k (at perm 0))
  (if (eq? k 0) flips
    (begin
      (reverse-prefix perm k)
      (flips-of perm (+ flips 1)))))

(defn fannkuch (n)
  (define perm1 (range n))
  (define count (zeros n))
  (define perm (zeros n))
  (define max-flips 0)
  (define checksum 0)
  (define permutations 0)
  (define r n)
  (define result nil)
  (defn next-permutation ()
    (if (eq? r n)
      (set! result (list checksum max-flips))
      (begin
        (rotate-left perm1 r)
        (at+= count r -1)
        (if (> (at count r) 0)
          (step)
          (begin
            (+= r 1)
            (next-permutation))))))
  (defn step ()
    (while-r)
    (for (i (range n))
      (vset! perm i (at perm1 i)))
    (define flips (flips-of perm 0))
    (if (> flips max-flips) (set! max-flips flips))
    (+= checksum (if (eq? (mod permutations 2) 0) flips (- 0 flips)))
    (+= permutations 1)
    (next-permutation))
  (defn while-r ()
    (if (eq? r 1) 0
      (begin
        (vset! count (- r 1) r)
        (-= r 1)
        (while-r))))
  (step)
  result)

(define result (fannkuch 9))
(print (at result 0) (at result 1))
