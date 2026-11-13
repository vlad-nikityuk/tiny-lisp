;; Neural-net building blocks on top of examples/autograd.lisp (load that first): Python-style list helpers, parameter
;; matrices, linear/softmax/rmsnorm, and blocks. A block is a function from a vector to a vector; (chain a b c) feeds a
;; vector through them in turn, and Residual adds a block's input to its output.

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
(defn Residual (block) (lambda (x) (for/list ((a b) (zip (block x) x)) (val a + b))))
