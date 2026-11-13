;; Neural-net building blocks on top of the autograd engine (loaded here): Python-style list helpers, parameter
;; matrices, linear/softmax/rmsnorm, and blocks. A block is a function from a vector to a vector; (chain a b c) feeds a
;; vector through them in turn, and Residual adds a block's input to its output.

(load "examples/autograd.lisp")

;; Python builtins and helpers
;; ----------------------------------------------------------------
(defn gauss (std) (* std (sqrt (* -2 (log (rand)))) (cos (* 2 pi (rand)))))
(defn min (a b) (if (< a b) a b))
(defn max (l) (reduce (rest l) (lambda (m x) (if (> x m) x m)) (first l)))
(defn mod (a b) (- a (* b (floor (/ a b)))))
(defn slice (l start end) (for/list (i (range (- end start))) (at l (+ start i))))
;; a list that grows in place, like a Python list with .append(): a one-slot list holding the items
(defn new-list () (list '()))
(defn append! (l x) (vset! l 0 (concat (at l 0) (list x))))
(defn items (l) (at l 0))
;; a dict, like a Python dict that is filled in order: a growable list of (key value) pairs
(defn new-dict () (new-list))
(defn dict-set! (d key x) (append! d (list key x)))
(defn dict-get-from (pairs key i)
  (if (eq? i (len pairs)) (error key)
    (if (eq? (first (at pairs i)) key) (second (at pairs i)) (dict-get-from pairs key (+ i 1)))))
(defn dict-get (d key) (dict-get-from (items d) key 0))
(defn dict-values (d) (for/list (kv (items d)) (second kv)))
(defn flatten (l) (r/reduce l concat '()))

;; parameters
;; ----------------------------------------------------------------
(defn matrix (nout nin) (for/list (i (range nout)) (for/list (j (range nin)) (param (gauss 0.08)))))

;; layers
;; ----------------------------------------------------------------
(defn linear (x w)
  (for/list (wo w) (vsum (for/list ((wi xi) (zip wo x)) (val wi * xi)))))

(defn softmax (logits)
  (define max-val (max (for/list (l logits) (data l))))
  (define exps (for/list (l logits) (vexp (val l - max-val))))
  (define total (vsum exps))
  (for/list (e exps) (val e / total)))

(defn rmsnorm (x)
  (define ms (val (vsum (for/list (xi x) (val xi * xi))) / (len x)))
  (define scale (val (ms + 0.00001) ** -0.5))
  (for/list (xi x) (val xi * scale)))

;; blocks
;; ----------------------------------------------------------------
(defn Linear (w) (lambda (x) (linear x w)))
(define ReLU (lambda (x) (for/list (xi x) (vrelu xi))))
;; x + block(x), as in `x = [a + b for a, b in zip(x, x_residual)]`
(defn Sequential (blocks) (lambda (x) (reduce blocks (lambda (acc block) (block acc)) x)))
(defn Residual (block) (lambda (x) (for/list ((a b) (zip (block x) x)) (val a + b))))
