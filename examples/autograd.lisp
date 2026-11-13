;; A scalar autograd engine: the Value class of microgpt.py, loaded by examples/microgpt.lisp. It builds the same graph:
;; a constant combined with a value is wrapped in a value of its own, every value keeps its children and their local grads,
;; and backward finds a topological order by depth-first search, then walks it in reverse.
;; A value is a mutable list, like a slotted object: (data grad children local-grads visited next).
;; (vset! v i x) stores into it in place; `visited` is the search's mark and `next` links the finished values.
;;
;; (val a * b + 0.5) is Python's a * b + 0.5 on values: + - * / ** and unary - with Python's precedence. Operands are
;; single expressions (a name, a number, a call) or parenthesised sub-expressions: (val (a + b) ** -0.5). A list whose second
;; element is an operator is read as infix, anything else is an ordinary call. A number is wrapped in a value of its own,
;; and a number on the left works like __radd__/__rmul__ (the value stays the first child).
;; (val a - b) is a + (-b), (val a / b) is a * b ** -1, as in the class; -x or x / n on a plain number stays a number.
(define topo-stamp 0) ; each backward uses a new stamp, so no mark ever needs clearing
(define topo-head nil) ; the value finished last: the head of the reverse topological order

;; val: infix arithmetic on values
;; ----------------------------------------------------------------
;; each level returns (expr rest-of-tokens); operands are the tokens themselves
(defn val/op? (x) (|| (eq? x "+") (eq? x "-") (eq? x "*") (eq? x "/") (eq? x "**")))

(defn val/atom (x) (if (&& (list? x) (val/op? (second x))) (first (val/sum x)) x))

(defn val/unary (ts)               ; -x, x ** y (the exponent may be negative: x ** -y)
  (if (eq? (first ts) "-")
    (begin
      (define operand (val/unary (rest ts)))
      (list (list "vneg" (first operand)) (second operand)))
    (if (eq? (second ts) "**")
      (begin
        (define exponent (val/unary (rest (rest ts))))
        (list (list "vpow" (val/atom (first ts)) (first exponent)) (second exponent)))
      (list (val/atom (first ts)) (rest ts)))))

(defn val/fold (operand build op1 op2 acc ts)
  (if (|| (eq? (first ts) op1) (eq? (first ts) op2))
    (begin
      (define rhs (operand (rest ts)))
      (val/fold operand build op1 op2 (build (first ts) acc (first rhs)) (second rhs)))
    (list acc ts)))

(defn val/term (ts)
  (define lhs (val/unary ts))
  (val/fold val/unary (lambda (op a b) (list (if (eq? op "*") "v*" "v/") a b)) "*" "/" (first lhs) (second lhs)))

(defn val/sum (ts)
  (define lhs (val/term ts))
  (val/fold val/term (lambda (op a b) (list "v+" a (if (eq? op "+") b (list "vneg" b)))) "+" "-" (first lhs) (second lhs)))

(defmacro val (& tokens)
  (first (val/sum tokens)))

;; Value
;; ----------------------------------------------------------------
;; Field access reads like attributes and costs nothing, because these are macros: (data v) is (at v 0), (grad v) is
;; (at v 1), and so on; (set-grad! v x) stores in place; (Value data children local-grads) is a list with the search
;; fields (visited, next) at their start values.
(defmacro data (v) `(at ~v 0))
(defmacro grad (v) `(at ~v 1))
(defmacro children (v) `(at ~v 2))
(defmacro local-grads (v) `(at ~v 3))
(defmacro visited (v) `(at ~v 4))
(defmacro next (v) `(at ~v 5))
(defmacro set-data! (v x) `(vset! ~v 0 ~x))
(defmacro set-grad! (v x) `(vset! ~v 1 ~x))
(defmacro set-visited! (v x) `(vset! ~v 4 ~x))
(defmacro set-next! (v x) `(vset! ~v 5 ~x))
(defmacro Value (d c lg) `(list ~d 0 ~c ~lg 0 nil))

(defn param (x) (Value x '() '()))
(defn const (x) (Value x '() '()))
(defn value (x) (if (list? x) x (const x)))

(defn v+ (a b)
  (define self (if (list? a) a b))
  (define other (if (list? a) (value b) (const a)))
  (Value (+ (data self) (data other)) (list self other) '(1 1)))
(defn v* (a b)
  (define self (if (list? a) a b))
  (define other (if (list? a) (value b) (const a)))
  (Value (* (data self) (data other)) (list self other) (list (data other) (data self))))
(defn vpow (a p) (Value (exp (* p (log (data a)))) (list a) (list (* p (exp (* (- p 1) (log (data a))))))))
(defn vlog (a) (Value (log (data a)) (list a) (list (/ 1 (data a)))))
(defn vexp (a)
  (define e (exp (data a)))
  (Value e (list a) (list e)))
(defn vrelu (a) (Value (if (> (data a) 0) (data a) 0) (list a) (list (if (> (data a) 0) 1 0))))
(defn vneg (a) (if (list? a) (val a * -1) (- 0 a)))   ; -x of a plain number stays a number
(defn v/ (a b) (val a * (if (list? b) (vpow b -1) (/ 1 b))))
(defn vsum (vs) (reduce vs v+ (const 0)))

;; depth-first: finish the children first, then v goes to the front of the list
(defn build-topo (v)
  (if (eq? (visited v) topo-stamp) 0
    (begin
      (set-visited! v topo-stamp)
      (for (child (children v)) (build-topo child))
      (set-next! v topo-head)
      (set! topo-head v))))

;; child.grad += local_grad * v.grad for each child
(defn push-grads (v)
  (for ((child local-grad) (zip (children v) (local-grads v)))
    (set-grad! child (+ (grad child) (* local-grad (grad v))))))

(defn walk (v) (if (eq? v nil) 0 (begin (push-grads v) (walk (next v)))))

(defn backward (loss)
  (set! topo-stamp (+ topo-stamp 1))
  (set! topo-head nil)
  (build-topo loss)
  (set-grad! loss 1)
  (walk topo-head))
