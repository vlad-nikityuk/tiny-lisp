; Byte-pair encoding as in minbpe: repeatedly merge the most frequent adjacent pair, on the first 1000 names of
; examples/names.txt as token ids (a-z = 0..25, newline = 26). Pair counts live in a flat table, so no dict is needed.
; (Python grows `out` with append; here it is a preallocated vector and a count.)
(load "bench/prelude.lisp")

(define docs (filter (split (read-file "examples/names.txt") newline) (lambda (line) line)))
(define uchars (split "abcdefghijklmnopqrstuvwxyz" ""))
(defn index-from (l x i) (if (eq? x (at l i)) i (index-from l x (+ i 1))))
(defn index-of (l x) (index-from l x 0))

(define ids
  (flatten
    (for/list (doc (slice docs 0 1000))
      (concat (for/list (ch (split doc "")) (index-of uchars ch)) (list 26)))))

; the ids after merging the pair (a b) into new-id: one pass, writing into a vector
(defn merge (ids a b new-id)
  (define out (zeros (len ids)))
  (define size (merge-from ids a b new-id out 0 0))
  (slice out 0 size))
(defn merge-from (ids a b new-id out i size)
  (if (< i (len ids))
    (if (&& (< i (- (len ids) 1)) (eq? (at ids i) a) (eq? (at ids (+ i 1)) b))
      (begin
        (vset! out size new-id)
        (merge-from ids a b new-id out (+ i 2) (+ size 1)))
      (begin
        (vset! out size (at ids i))
        (merge-from ids a b new-id out (+ i 1) (+ size 1))))
    size))

(define n-merges 120)
(define width (+ 27 n-merges))
(define merges (zeros n-merges))
(for (m (range n-merges))
  (define counts (zeros (* width width)))
  (for ((a b) (zip ids (rest ids)))
    (at+= counts (+ (* a width) b) 1))
  (define best 0)
  (for (k (range (len counts)))
    (if (> (at counts k) (at counts best)) (set! best k)))
  (define a (floor (/ best width)))
  (define b (mod best width))
  (set! ids (merge ids a b (+ 27 m)))
  (vset! merges m (+ (* a 1000) b)))
(print (len ids) (sum merges) (at merges 0) (at merges (- n-merges 1)))
