;; microgpt: Karpathy's microgpt.py (https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95)
;; ported to tinylisp: a scalar autograd engine (examples/autograd.lisp), a one-layer GPT, Adam, sampling.
;; Run from the repo root:  ./tinylisp -f examples/microgpt.lisp
;; Differences from the gist: a fixed a-z alphabet, the first 1000 names of names.txt, and the stdlib's Park-Miller generator
;; (rand) instead of Python's random, so a Python run with the same generator prints the same losses.
;; The code follows the gist line by line, helped by macros: (defn f (args) expr...) with a body of several expressions,
;; (for (x lst) ...) and (for/list (x lst) ...) for loops and comprehensions (a pattern (a b) unpacks pairs, as with zip),
;; and (val a * b + c) for arithmetic on values (examples/autograd.lisp).
(define num-steps 10)
(define num-samples 5)
(load "examples/autograd.lisp")

;; ---------------------------------------------------------------- Python builtins and helpers
(defn gauss (std) (* std (sqrt (* -2 (log (rand)))) (cos (* 2 pi (rand)))))
(defn min (a b) (if (< a b) a b))
(defn max (l) (reduce (rest l) (lambda (m x) (if (> x m) x m)) (first l)))
(defn mod (a b) (- a (* b (floor (/ a b)))))
(defn slice (l start end) (for/list (i (range (- end start))) (at l (+ start i))))
;; a list that grows in place, like a Python list with .append(): a one-slot list holding the items
(defn new-list () (list '()))
(defn append! (l x) (vset! l 0 (concat (at l 0) (list x))))
(defn items (l) (at l 0))

;; ---------------------------------------------------------------- dataset and tokenizer
(define docs (reduce (split (read-file "examples/names.txt") "
") (lambda (acc s) (if s (concat acc (list s)) acc)) '()))
(define uchars (split "abcdefghijklmnopqrstuvwxyz" ""))
(define BOS 26)
(define vocab-size 27)
(defn index-of (ch l i) (if (eq? ch (at l i)) i (index-of ch l (+ i 1))))
(defn tokenize (doc) (concat (list BOS) (for/list (ch (split doc "")) (index-of ch uchars 0)) (list BOS)))

;; ---------------------------------------------------------------- parameters
(define n-embd 16)
(define block-size 16)
(define n-head 4)
(define head-dim 4)

(defn matrix (nout nin) (for/list (i (range nout)) (for/list (j (range nin)) (param (gauss 0.08)))))
(define wte (matrix vocab-size n-embd))
(define wpe (matrix block-size n-embd))
(define lm-head (matrix vocab-size n-embd))
(define attn-wq (matrix n-embd n-embd))
(define attn-wk (matrix n-embd n-embd))
(define attn-wv (matrix n-embd n-embd))
(define attn-wo (matrix n-embd n-embd))
(define mlp-fc1 (matrix (* 4 n-embd) n-embd))
(define mlp-fc2 (matrix n-embd (* 4 n-embd)))
(defn flatten (m) (r/reduce m concat '()))
(define params
  (r/reduce (list wte wpe lm-head attn-wq attn-wk attn-wv attn-wo mlp-fc1 mlp-fc2)
            (lambda (m acc) (concat (flatten m) acc)) '()))
(define n-params (len params))
(print "num docs:" (len docs))
(print "vocab size:" vocab-size)
(print "num params:" n-params)

;; ---------------------------------------------------------------- model
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

;; one attention head: the slice [hs, hs + head-dim) of q, of every cached key and of every cached value
(defn attention-head (q keys values hs)
  (define q-h (slice q hs (+ hs head-dim)))
  (define k-h (for/list (ki keys) (slice ki hs (+ hs head-dim))))
  (define v-h (for/list (vi values) (slice vi hs (+ hs head-dim))))
  (define attn-logits
    (for/list (k k-h) (val (vsum (for/list ((qj kj) (zip q-h k)) (val qj * kj))) / (sqrt head-dim))))
  (define attn-weights (softmax attn-logits))
  (for/list (j (range head-dim))
    (vsum (for/list ((w vt) (zip attn-weights v-h)) (val w * (at vt j))))))

;; ---- blocks: a block is a function from a vector to a vector; (chain a b c) feeds a vector through them in turn
(defn Linear (w) (lambda (x) (linear x w)))
(define ReLU (lambda (x) (for/list (xi x) (vrelu xi))))
;; x + block(x), as in `x = [a + b for a, b in zip(x, x_residual)]`
(defn Residual (block) (lambda (x) (for/list ((a b) (zip (block x) x)) (val a + b))))

;; multi-head attention: caches this position's key and value, then every head looks at all the cached positions
(defn Attention (keys values)
  (fn (x)
    (define q (linear x attn-wq))
    (define k (linear x attn-wk))
    (define v (linear x attn-wv))
    (append! keys k)
    (append! values v)
    (define x-attn '())
    (for (h (range n-head))
      (set! x-attn (concat x-attn (attention-head q (items keys) (items values) (* h head-dim)))))
    x-attn))

(define mlp-block (Residual (chain rmsnorm (Linear mlp-fc1) ReLU (Linear mlp-fc2))))

;; (gpt token-id pos-id keys values) -> logits; the key/value caches grow by one position
(defn gpt (token-id pos-id keys values)
  (define attn-block (Residual (chain rmsnorm (Attention keys values) (Linear attn-wo))))
  (define transformer (chain rmsnorm attn-block mlp-block (Linear lm-head)))
  (-> (for/list ((t p) (zip (at wte token-id) (at wpe pos-id))) (val t + p))
      transformer))

;; ---------------------------------------------------------------- Adam
(define learning-rate 0.01)
(define beta1 0.85)
(define beta2 0.99)
(define eps-adam 0.00000001)
(define m (for/list (p params) 0))
(define v (for/list (p params) 0))

(defn adam-update (step)
  (define lr-t (* learning-rate (- 1 (/ step num-steps))))
  (define bias1 (- 1 (exp (* (+ step 1) (log beta1)))))
  (define bias2 (- 1 (exp (* (+ step 1) (log beta2)))))
  (for (i (range n-params))
    (define p (at params i))
    (vset! m i (+ (* beta1 (at m i)) (* (- 1 beta1) (grad p))))
    (vset! v i (+ (* beta2 (at v i)) (* (- 1 beta2) (* (grad p) (grad p)))))
    (define m-hat (/ (at m i) bias1))
    (define v-hat (/ (at v i) bias2))
    (set-data! p (- (data p) (/ (* lr-t m-hat) (+ (sqrt v-hat) eps-adam))))
    (set-grad! p 0)))

;; ---------------------------------------------------------------- training
(defn round4 (x) (/ (floor (+ (* x 10000) 0.5)) 10000))

(for (step (range num-steps))
  (define doc (at docs (mod step (len docs))))
  (define tokens (tokenize doc))
  (define n (min block-size (- (len tokens) 1)))
  ;; forward the token sequence, building the graph up to the loss
  (define keys (new-list))
  (define values (new-list))
  (define losses (new-list))
  (for (pos-id (range n))
    (define token-id (at tokens pos-id))
    (define target-id (at tokens (+ pos-id 1)))
    (define probs (-> (gpt token-id pos-id keys values) softmax))
    (define loss-t (-> probs (at target-id) vlog vneg))
    (append! losses loss-t))
  (define loss (val (/ 1 n) * (vsum (items losses))))
  (backward loss)
  (adam-update step)
  (print "step" (+ step 1) "/" num-steps "| loss" (round4 (data loss))))

;; ---------------------------------------------------------------- inference
(define temperature 0.5)

;; pick an index with probability proportional to its weight
(defn draw-loop (weights r i acc)
  (if (|| (eq? i (- (len weights) 1)) (< r (+ acc (at weights i)))) i
    (draw-loop weights r (+ i 1) (+ acc (at weights i)))))
(defn draw (weights) (draw-loop weights (* (rand) (reduce weights + 0)) 0 0))

(defn sample-loop (pos-id token-id keys values sample)
  (if (eq? pos-id block-size) sample
    (begin
      (define logits (gpt token-id pos-id keys values))
      (define probs (softmax (for/list (l logits) (val l / temperature))))
      (define next-id (draw (for/list (p probs) (data p))))
      (if (eq? next-id BOS) sample
        (sample-loop (+ pos-id 1) next-id keys values (+ sample (at uchars next-id)))))))

(print "--- inference (new, hallucinated names) ---")
(for (sample-idx (range num-samples))
  (print "sample" (+ sample-idx 1) ":" (sample-loop 0 BOS (new-list) (new-list) "")))
