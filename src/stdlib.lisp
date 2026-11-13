;; Lisp part of the stdlib, loaded after the native part (src/stdlib_native.zig).
(define pi 3.141592653589793)
(define first car)
(define rest cdr)

;; several expressions in a row become one (begin ...)
(define seq
  (lambda (exprs)
    (if (eq? (len exprs) 1) (first exprs) (cons "begin" exprs))))

;; shorthand for defining functions; the body may be several expressions
;; (defn name args expr...) -> (define name (lambda args (begin expr...)))
;; (defn _add (a b) (+ a b))
(define macro/defn
  (lambda (ast)
    (if (eq? (first ast) "defn")
      (begin
        (define body (rest ast))
        (list "define" (first body) (list "lambda" (first (rest body)) (seq (rest (rest body))))))
      ast)))

;; (fn (args) expr...) is a lambda whose body may be several expressions
(define macro/fn
  (lambda (ast)
    (if (eq? (first ast) "fn")
      (list "lambda" (second ast) (seq (rest (rest ast))))
      ast)))

(defn not (x) (if x #f #t))
(defn second (l) (first (rest l)))
(defn third (l) (first (rest (rest l))))

;; (for/bindings (a b) 0) -> ((define a (at for/item 0)) (define b (at for/item 1)))
(defn for/bindings (names i)
  (if (eq? (len names) 0) '()
    (cons (list "define" (first names) (list "at" "for/item" i)) (for/bindings (rest names) (+ i 1)))))

;; the lambda of a loop; a variable written as a pattern (a b) takes each item (a list) apart
(defn for/lambda (var body)
  (if (list? var)
    (list "lambda" (list "for/item") (seq (concat (for/bindings var 0) body)))
    (list "lambda" (list var) (seq body))))

;; the loop as a map call; over (zip xs ys) it walks the lists side by side, without building the pairs
(defn for/map (var source body)
  (if (&& (list? var) (eq? (first source) "zip"))
    (concat (list "map") (rest source) (list (list "lambda" var (seq body))))
    (list "map" source (for/lambda var body))))

;; loops over a list, like Python's for and list comprehensions
;; (for (x lst) body...)      -> (begin (map lst (lambda (x) body...)) nil)
;; (for/list (x lst) body...) -> (map lst (lambda (x) body...))
;; (for/list ((a b) (zip xs ys)) (* a b)) -> (map xs ys (lambda (a b) (* a b)))
(define macro/for
  (lambda (ast)
    (if (eq? (first ast) "for")
      (list "begin" (for/map (first (first (rest ast))) (second (first (rest ast))) (rest (rest ast))) "nil")
      ast)))

(define macro/for/list
  (lambda (ast)
    (if (eq? (first ast) "for/list")
      (for/map (first (first (rest ast))) (second (first (rest ast))) (rest (rest ast)))
      ast)))
;; (-> x step...) threads a value through the steps, like a stream pipeline: a name f is (f x), a form (f a) is (f x a)
;; (-> probs (at 3) vlog vneg) -> (vneg (vlog (at probs 3)))
(defn thread-step (x step)
  (if (list? step) (cons (first step) (cons x (rest step))) (list step x)))

(define macro/->
  (lambda (ast)
    (if (eq? (first ast) "->")
      (reduce (rest (rest ast)) thread-step (second ast))
      ast)))

;; (chain block...) is the block that feeds its input through the blocks in turn, like Keras's Sequential. A block is any
;; expression whose value is a function of one argument; each is evaluated once, when the chain is built.
;; (chain rmsnorm (Linear w) relu) -> ((lambda (b0 b1 b2) (lambda (x) (b2 (b1 (b0 x))))) rmsnorm (Linear w) relu)
(define macro/chain
  (lambda (ast)
    (if (eq? (first ast) "chain")
      (begin
        (define names (map (range (len (rest ast))) (lambda (i) (+ "chain/b" i))))
        (cons (list "lambda" names (list "lambda" (list "chain/x") (reduce names (lambda (acc name) (list name acc)) "chain/x")))
              (rest ast)))
      ast)))


(defn patch-rec-trampoline (ast name)
  (if (list? ast)
    (if (eq? name (first ast))
      ;; ast: (a 1 2 3)
      ;; res: (lambda () (a 1 2 3))
      (list "lambda" '() ast)
      (map ast (lambda (x) (patch-rec-trampoline x name))))
    ast))
;; ------------- UTILS ----------------------------------------
(defn trace (x) (begin (print x) x))
(defn pass () 0)
(defn color (code x) (+ ESC "[" code "m" x ESC "[39m"))
(defn red (x) (color 31 x))
(defn green (x) (color 32 x))
;; Park-Miller random numbers in [0, 1); (set! rng-state n) reseeds.
(define rng-state 20240607)
(defn rand ()
  (begin
    (set! rng-state (- (* 16807 rng-state) (* 2147483647 (floor (/ (* 16807 rng-state) 2147483647)))))
    (/ rng-state 2147483647)))
;; ;; ------------ LISTS ----------------------------------------
(defn empty? (lst) (eq? (len lst) 0))

(defn iterate (lst f) (begin (map lst f) nil))

(defn l/reduce (lst f memo)
  (if (empty? lst) memo
    (reduce (rest lst) f (f (first lst) memo))))

(defn r/reduce (lst f memo)
  (if (empty? lst) memo
    (f (first lst) (r/reduce (rest lst) f memo))))

;; (iterate (zip '(1 2 3) '(4 5 6)) print)


;; -----------------------------------------------------------
;; (define macro/trace trace)
;; -----------------------------------------------------------

(define macro/defrec
  (lambda (ast)
    (if (eq? (first ast) "defrec")
      (begin
        (define body (rest ast))
        (define name (first body))
        (define args (first (rest body)))
        (define expr (patch-rec-trampoline (first (rest (rest body))) name))
        (list "define" name (list "trampoline" (list "lambda" args expr))))
      ast)))

;; Linked lists
(defn c/cons (v lst)
  (lambda (f) (f v lst)))

(defn c/head (lst)
  (lst (lambda (h t) h)))

(defn c/tail (lst)
  (lst (lambda (h t) t)))

;;-------------- UNIT TESTS -----------------------------------
(defn assert (expr)
  (if (eq? #f expr)
    (begin
      (error "assertion-failed")
      #f)
    #t))

(define *TESTS* '())

(defn equal? (a1 a2)
  (if (&& (list? a1) (list? a2))
      (r/reduce (zip a1 a2) (lambda (x m)
			      (begin
			       (define v1 (first x))
			       (define v2 (first (rest x)))
			       (eq? v1 v2)))
		#t)
    (eq? a1 a2)))

(define macro/xdeftest
  (lambda (ast)
    (if (eq? (first ast) "xdeftest") '(pass) ast)))

(define macro/deftest
  (lambda (ast)
    (if (eq? (first ast) "deftest")
      (begin
        (define body (rest ast))
        (define name (first body))
        (define test (first (rest body)))
        ;; test-name ; test-fn pair
        (define test-definition (list "list" (list "quote" name) name))
        (define tests-var "*TESTS*")
        (list (quote begin)
          (list "define" name (list "lambda" '() test))
          (list "set!" tests-var
            (list "concat" tests-var (list "list" test-definition)))))
      ast)))

;;(patch-asserts (quote
;; ast  (deftest failing-test (assert (eq? #f #t))))
;; name (quote failing-test)
;; expr (quote (+ 1 2)))
(defn patch-asserts (ast test-name assertion-expr)
  (begin
    (defn patch-assert (_ast_)
      (if (eq? (first _ast_) "assert")
        (begin
          (define body (rest _ast_))
          (define expr (first body))
          (define messages (rest body))
          (define q-str "quote")
          ;(assert test-exp
          ;	  (quote test:)
          ;	  (quote test-name)
          ;	  (quote expression:)
          ;	  (quote assertion-expr)
          ;	  messages..)

          (concat
            (list
              "assert"
              assertion-expr
              (list q-str "test:")
              (list q-str test-name)
              (list q-str "expression:")
              (list q-str assertion-expr))
            messages)
          _ast_)))

   (defn patch-rec (_ast_)
     (begin
      (define _new_ast_ (patch-assert _ast_))
      (if (list? _new_ast_)
	      (map _new_ast_ patch-rec)
	      _new_ast_)))
  (patch-rec ast)))

(defn run-tests ()
  (iterate *TESTS*
	   (lambda (test)
	     (begin
	      (define name (first test))
	      (define test-fn (first (rest test)))
	      (test-fn)
	      (print (green "PASS") name)))))
