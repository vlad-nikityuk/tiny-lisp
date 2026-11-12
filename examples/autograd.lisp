;; A scalar autograd engine: the Value class of microgpt.py, loaded by examples/microgpt.lisp. It builds the same graph:
;; a constant combined with a value is wrapped in a value of its own, every value keeps its children and their local grads,
;; and backward finds a topological order by depth-first search, then walks it in reverse.
;; A value is a mutable list, like a slotted object: (data grad children local-grads visited next).
;; (vset! v i x) stores into it in place; `visited` is the search's mark and `next` links the finished values.
(define topo-stamp 0) ; each backward uses a new stamp, so no mark ever needs clearing
(define topo-head nil) ; the value finished last: the head of the reverse topological order

(defn param (x) (list x 0 '() '() 0 nil))
(defn const (x) (list x 0 '() '() 0 nil))
(defn data (v) (at v 0))
(defn grad (v) (at v 1))
(defn v+ (a b) (list (+ (at a 0) (at b 0)) 0 (list a b) '(1 1) 0 nil))
(defn v* (a b) (list (* (at a 0) (at b 0)) 0 (list a b) (list (at b 0) (at a 0)) 0 nil))
(defn v+c (a x) (v+ a (const x)))
(defn v*c (a x) (v* a (const x)))
(defn vpow (a p)
  (begin
    (define d (at a 0))
    (list (exp (* p (log d))) 0 (list a) (list (* p (exp (* (- p 1) (log d))))) 0 nil)))
(defn vlog (a) (list (log (at a 0)) 0 (list a) (list (/ 1 (at a 0))) 0 nil))
(defn vexp (a)
  (begin
    (define e (exp (at a 0)))
    (list e 0 (list a) (list e) 0 nil)))
(defn vrelu (a)
  (begin
    (define d (at a 0))
    (list (if (> d 0) d 0) 0 (list a) (list (if (> d 0) 1 0)) 0 nil)))
(defn vneg (a) (v*c a -1))
(defn v/ (a b) (v* a (vpow b -1)))
(defn vsum (vs) (reduce vs v+ (const 0)))

;; depth-first: finish the children first, then v goes to the front of the list
(defn build-topo (v)
  (if (eq? (at v 4) topo-stamp) 0
    (begin
      (define children (at v 2))
      (vset! v 4 topo-stamp)
      (if (> (len children) 0) (build-topo (at children 0)))
      (if (> (len children) 1) (build-topo (at children 1)))
      (vset! v 5 topo-head)
      (set! topo-head v))))

;; child.grad += local_grad * v.grad for each child
(defn push-grads (v)
  (begin
    (define children (at v 2))
    (define local-grads (at v 3))
    (define g (at v 1))
    (if (> (len children) 0) (vset! (at children 0) 1 (+ (at (at children 0) 1) (* (at local-grads 0) g))))
    (if (> (len children) 1) (vset! (at children 1) 1 (+ (at (at children 1) 1) (* (at local-grads 1) g))))))

(defn walk (v) (if (eq? v nil) 0 (begin (push-grads v) (walk (at v 5)))))

(defn backward (loss)
  (begin
    (set! topo-stamp (+ topo-stamp 1))
    (set! topo-head nil)
    (build-topo loss)
    (vset! loss 1 1)
    (walk topo-head)))
