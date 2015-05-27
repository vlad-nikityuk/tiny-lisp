;; shorthand for defining functions
;; (defn name args expr) -> (define name (lambda args expr))
;; (defn _add (a b) (+ a b))
(define macro/defn
  (lambda (ast)
    (if (eq? (car ast) (quote defn))
	(begin
	 (define body (cdr ast))
	 (define name (car body))
	 (define args (car (cdr body)))
	 (define expr (car (cdr (cdr body))))
	 (list (quote define) name (list (quote lambda) args expr)))
      ast)))

(defn not (x) (if x #f #t))
;; ------------- UTILS ----------------------------------------
(define print (js/eval (quote console.log)))
(define pi (js/eval (quote Math.PI)))

(defn trace (x) (begin (print x) x))

(define first car)
(define rest cdr)
;; -----------------------------------------------------------
(if *DEBUG*
    (define macro/trace trace))
;; ------------ LISTS ----------------------------------------
;; (empty? 0) => true
;; (empty? 1) => false
(defn empty? (lst) (eq? (len lst) 0))

;; doesn't pass the (list? (quote ())) test
(defn list? (lst) (not (eq? (car lst) nil)))

(defn iterate (lst f)
  (if (not (empty? lst))
      (begin
       (f (car lst))
       (iterate (cdr lst) f))))

(defn reduce (lst f memo)
    (if (empty? lst) memo
      (reduce (cdr lst) f (f (car lst) memo))))

(defn r/reduce (lst f memo)
    (if (empty? lst) memo
      (f (car lst) (r/reduce (cdr lst) f memo))))

(defn concat (l1 l2)
  (r/reduce l1 cons l2))

(defn map (xs f)
    (r/reduce xs (lambda (x m) (cons (f x) m)) (list)))

;(defn tr/map (f)
;  (

;; Linked lists
(defn c/cons (v lst)
  (lambda (f) (f v lst)))

(defn c/head (lst)
  (lst (lambda (h t) h)))

(defn c/tail (lst)
  (lst (lambda (h t) t)))

;;-------------- UNIT TESTS -----------------------------------
(define assert (js/eval (quote console.assert)))
(define *TESTS* (quote ()))

(define macro/deftest
  (lambda (ast)
    (if (eq? (car ast) (quote deftest))
	(begin
	 (define body (cdr ast))
	 (define name (car body))
	 (define test (car (cdr body)))
	 ;; test-name ; test-fn pair
	 (define test-definition (list (quote list) (list (quote quote) name) name))
	 (define tests-var (quote *TESTS*))
	 (list (quote begin)
	       (list (quote define) name (list (quote lambda) (quote ()) test))
	       (list (quote set!) tests-var
		     (list (quote concat) tests-var (list (quote list) test-definition)))))
      ast)))

;;(patch-asserts (quote (deftest failing-test (assert (eq? #f #t)))) (quote failing-test) (quote (+ 1 2)))
(defn patch-asserts (ast test-name assertion-expr)
  (begin
   (defn patch-assert (_ast_)
     (if (eq? (car _ast_) (quote assert))
	 (begin
	  (define body (cdr _ast_))
	  (define expr (car body))
	  (define messages (cdr body))

	  (define q-str (quote quote))
	  ;;(assert test-exp (quote test:) (quote test-name) (quote expression:) (quote assertion-expr) messages..)
	  (concat (list (quote assert)
			assertion-expr
			(list q-str (quote test:))
			(list q-str test-name)
			(list q-str (quote expression:))
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
	      (define name (car test))
	      (define test-fn (car (cdr test)))
	      (test-fn)
	      (print (quote ✓) name)))))

