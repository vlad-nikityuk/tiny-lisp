;; Python builtins and operators for the benchmark ports, so each .lisp reads like the .py next to it.
;; Run from the repo root: ./tinylisp -f bench/NAME.lisp

(defn abs (x) (if (< x 0) (- 0 x) x))
(defn mod (a b) (- a (* b (floor (/ a b))))) ; a % b, also for negative a
(defn sum (l) (reduce l + 0))
(defn items-of (args) (if (&& (eq? (len args) 1) (list? (first args))) (first args) args))
(defn min (& args)
  (define l (items-of args))
  (reduce (rest l) (lambda (m x) (if (< x m) x m)) (first l)))
(defn max (& args)
  (define l (items-of args))
  (reduce (rest l) (lambda (m x) (if (> x m) x m)) (first l)))

;; l[start:end]
(defn slice (l start end) (for/list (i (range (max 0 (- end start)))) (at l (+ start i))))

;; [0] * n, and the ranges Python has: range(a, b) and range(a, b, step), also counting down
(defn zeros (n) (for/list (_ (range n)) 0))
(defn range-between (a b) (for/list (i (range (max 0 (- b a)))) (+ a i)))
(defn range-step (a b s)
  (define count (if (> s 0) (floor (/ (+ (- b a) (- s 1)) s)) (floor (/ (+ (- a b) (- (- 0 s) 1)) (- 0 s)))))
  (for/list (i (range (max 0 count))) (+ a (* i s))))

(defn swap! (a i j)
  (define t (at a i))
  (vset! a i (at a j))
  (vset! a j t))

;; x += v, x -= v for a variable, a[i] += v for a list item
(defmacro += (var x) `(set! ~var (+ ~var ~x)))
(defmacro -= (var x) `(set! ~var (- ~var ~x)))
(defmacro at+= (a i x) `(vset! ~a ~i (+ (at ~a ~i) ~x)))
