;; microgpt: Karpathy's microgpt.py (https://gist.github.com/karpathy/8627fe009c40f57531cb18360106ce95)
;; ported to tinylisp: a scalar autograd engine (examples/autograd.lisp), a one-layer GPT, Adam, sampling.
;; Run from the repo root:  ./tinylisp -f examples/microgpt.lisp
;; Differences from the gist: a fixed a-z alphabet, the first 1000 names of names.txt, and the stdlib's Park-Miller generator
;; (rand) instead of Python's random, so a Python run with the same generator prints the same losses.
(define num-steps 10)
(define num-samples 5)
(load "examples/autograd.lisp")

(defn gauss (std) (* std (sqrt (* -2 (log (rand)))) (cos (* 2 pi (rand)))))

(defn range-acc (i acc) (if (< i 0) acc (range-acc (- i 1) (cons i acc))))
(defn range (n) (range-acc (- n 1) '()))
(defn second (l) (first (rest l)))
(defn third (l) (first (rest (rest l))))

;; ---------------------------------------------------------------- dataset and tokenizer
(define docs (reduce (split (read-file "examples/names.txt") "
") (lambda (acc s) (if s (concat acc (list s)) acc)) '()))
(define uchars (split "abcdefghijklmnopqrstuvwxyz" ""))
(define BOS 26)
(define vocab-size 27)
(defn index-of (ch l i) (if (eq? ch (at l i)) i (index-of ch l (+ i 1))))
(defn tokenize (doc) (concat (cons BOS (map (split doc "") (lambda (ch) (index-of ch uchars 0)))) (list BOS)))

;; ---------------------------------------------------------------- parameters
(define n-embd 16)
(define block-size 16)
(define n-head 4)
(define head-dim 4)
(define idx-embd (range 16))
(define idx-mlp (range 64))
(define idx-head (range 4))

(defn matrix (nout nin) (map (range nout) (lambda (i) (map (range nin) (lambda (j) (param (gauss 0.08)))))))
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
(defn dot (w x idx) (vsum (map idx (lambda (i) (v* (at w i) (at x i))))))
(defn linear (x w idx) (map w (lambda (wo) (dot wo x idx))))
(defn add-vec (a b) (map idx-embd (lambda (i) (v+ (at a i) (at b i)))))

(defn softmax (logits)
  (begin
    (define top (reduce (rest logits) (lambda (m l) (if (> (data l) m) (data l) m)) (data (first logits))))
    (define exps (map logits (lambda (l) (vexp (v+c l (- 0 top))))))
    (define total (vsum exps))
    (map exps (lambda (e) (v/ e total)))))

(defn rmsnorm (x)
  (begin
    (define ms (v*c (vsum (map x (lambda (xi) (v* xi xi)))) (/ 1 (len x))))
    (define scale (vpow (v+c ms 0.00001) -0.5))
    (map x (lambda (xi) (v* xi scale)))))

;; one attention head: the slice [hs, hs + head-dim) of q, of every cached key and of every cached value
(defn attention-head (q ks vs hs)
  (begin
    (define logits
      (map ks (lambda (k) (v*c (vsum (map idx-head (lambda (j) (v* (at q (+ hs j)) (at k (+ hs j)))))) 0.5))))
    (define weighted (zip (softmax logits) vs))
    (map idx-head (lambda (j)
      (vsum (map weighted (lambda (p) (v* (first p) (at (second p) (+ hs j))))))))))

;; (gpt token pos keys values) -> (logits keys values); the key/value caches grow by one position
(defn gpt (token pos keys values)
  (begin
    (define x0 (rmsnorm (map idx-embd (lambda (i) (v+ (at (at wte token) i) (at (at wpe pos) i))))))
    ;; 1) multi-head attention block
    (define x1 (rmsnorm x0))
    (define q (linear x1 attn-wq idx-embd))
    (define k (linear x1 attn-wk idx-embd))
    (define v (linear x1 attn-wv idx-embd))
    (define keys2 (concat keys (list k)))
    (define values2 (concat values (list v)))
    (define x-attn
      (r/reduce (map (range n-head) (lambda (h) (attention-head q keys2 values2 (* h head-dim)))) concat '()))
    (define x2 (add-vec (linear x-attn attn-wo idx-embd) x0))
    ;; 2) MLP block
    (define x3 (rmsnorm x2))
    (define hidden (map (linear x3 mlp-fc1 idx-embd) vrelu))
    (define x4 (add-vec (linear hidden mlp-fc2 idx-mlp) x2))
    (list (linear x4 lm-head idx-embd) keys2 values2)))

;; ---------------------------------------------------------------- Adam
(define learning-rate 0.01)
(define beta1 0.85)
(define beta2 0.99)
(define eps-adam 0.00000001)
(defn cell (x) (list x))
(define m-buf (map params (lambda (p) (cell 0))))
(define v-buf (map params (lambda (p) (cell 0))))

(defn adam-loop (i lr-t bias1 bias2)
  (if (eq? i n-params) 0
    (begin
      (define p (at params i))
      (define g (grad p))
      (define mi (+ (* beta1 (at (at m-buf i) 0)) (* (- 1 beta1) g)))
      (define vi (+ (* beta2 (at (at v-buf i) 0)) (* (- 1 beta2) (* g g))))
      (vset! (at m-buf i) 0 mi)
      (vset! (at v-buf i) 0 vi)
      (vset! p 0 (- (at p 0) (/ (* lr-t (/ mi bias1)) (+ (sqrt (/ vi bias2)) eps-adam))))
      (vset! p 1 0)
      (adam-loop (+ i 1) lr-t bias1 bias2))))

(defn adam-update (step)
  (adam-loop 0 (* learning-rate (- 1 (/ step num-steps)))
             (- 1 (exp (* (+ step 1) (log beta1)))) (- 1 (exp (* (+ step 1) (log beta2))))))

;; ---------------------------------------------------------------- training
;; forward the token sequence, building the graph up to the loss
(defn forward-loop (pos n tokens keys values losses)
  (if (eq? pos n) losses
    (begin
      (define out (gpt (at tokens pos) pos keys values))
      (define probs (softmax (first out)))
      (define loss-t (vneg (vlog (at probs (at tokens (+ pos 1))))))
      (forward-loop (+ pos 1) n tokens (second out) (third out) (concat losses (list loss-t))))))

(defn round4 (x) (/ (floor (+ (* x 10000) 0.5)) 10000))

(defn train (step)
  (if (eq? step num-steps) 0
    (begin
      (define tokens (tokenize (at docs (- step (* (len docs) (floor (/ step (len docs))))))))
      (define n (if (< block-size (- (len tokens) 1)) block-size (- (len tokens) 1)))
      (define loss (v*c (vsum (forward-loop 0 n tokens '() '() '())) (/ 1 n)))
      (backward loss)
      (adam-update step)
      (print "step" (+ step 1) "/" num-steps "| loss" (round4 (data loss)))
      (train (+ step 1)))))
(train 0)

;; ---------------------------------------------------------------- inference
(define temperature 0.5)

;; pick an index with probability proportional to its weight
(defn draw-loop (weights r i acc)
  (if (|| (eq? i (- (len weights) 1)) (< r (+ acc (at weights i)))) i
    (draw-loop weights r (+ i 1) (+ acc (at weights i)))))
(defn draw (weights) (draw-loop weights (* (rand) (reduce weights + 0)) 0 0))

(defn sample-loop (pos token keys values name)
  (if (eq? pos block-size) name
    (begin
      (define out (gpt token pos keys values))
      (define probs (softmax (map (first out) (lambda (l) (v*c l (/ 1 temperature))))))
      (define next (draw (map probs data)))
      (if (eq? next BOS) name
        (sample-loop (+ pos 1) next (second out) (third out) (+ name (at uchars next)))))))

(print "--- inference (new, hallucinated names) ---")
(defn sample (i)
  (if (< i num-samples)
    (begin (print "sample" (+ i 1) ":" (sample-loop 0 BOS '() '() "")) (sample (+ i 1)))))
(sample 0)
