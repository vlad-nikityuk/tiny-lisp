;; shorthand for defining functions
;; (defn name args expr) -> (define name (lambda args expr))
;; (defn _add (a b) (+ a b))
(define macro/defn
  (lambda (ast)
    (if (eq? (car ast) 'defn)
	(begin
	 (define body (cdr ast))
	 (define name (car body))
	 (define args (car (cdr body)))
	 (define expr (car (cdr (cdr body))))
	 (list 'define name (list 'lambda args expr)))
      ast)))

(defn not (x) (if x #f #t))
;; ------------- UTILS ----------------------------------------
(define print (js/eval 'console.log))
(define pi (js/eval 'Math.PI))

(defn trace (x) (begin (print x) x))

(define first car)
(define rest cdr)
;; -----------------------------------------------------------
(if *DEBUG*
    (define macro/trace trace))
;; ------------ LISTS ----------------------------------------
(defn empty? (lst) (eq? (len lst) 0))
(define list? (js/eval 'Array.isArray))

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

;; (and doesn't work here for some reason, using (&&
;; (iterate (zip '(1 2 3) '(4 5 6)) print)
(defn zip (ll1 ll2)
  (if (&& (empty? ll1) (empty? ll2)) nil
    (cons (list (car ll1) (car ll2))
	  (zip (cdr ll1) (cdr ll2)))))

(defn concat (l1 l2)
  (r/reduce l1 cons l2))

(defn map (xs f)
  (r/reduce xs (lambda (x m) (cons (f x) m)) (list)))

;; Linked lists
(defn c/cons (v lst)
  (lambda (f) (f v lst)))

(defn c/head (lst)
  (lst (lambda (h t) h)))

(defn c/tail (lst)
  (lst (lambda (h t) t)))

;;-------------- COLORS -----------------------------------

(define red (js/eval 'colors.red))
(define green (js/eval 'colors.green))

;;-------------- UNIT TESTS -----------------------------------
(define assert (js/eval 'console.assert))
(define *TESTS* '())

(defn equal? (a1 a2)
  (if (&& (list? a1) (list? a2))
      (r/reduce (zip a1 a2) (lambda (x m)
			      (begin
			       (define v1 (car x))
			       (define v2 (car (cdr x)))
			       (eq? v1 v2)))
		#t)
    (eq? a1 a2)))

(define macro/deftest
  (lambda (ast)
    (if (eq? (car ast) 'deftest)
	(begin
	 (define body (cdr ast))
	 (define name (car body))
	 (define test (car (cdr body)))
	 ;; test-name ; test-fn pair
	 (define test-definition (list 'list (list 'quote name) name))
	 (define tests-var '*TESTS*)
	 (list (quote begin)
	       (list 'define name (list 'lambda '() test))
	       (list 'set! tests-var
		     (list 'concat tests-var (list 'list test-definition)))))
      ast)))

;;(patch-asserts (quote
;; ast  (deftest failing-test (assert (eq? #f #t))))
;; name (quote failing-test)
;; expr (quote (+ 1 2)))
(defn patch-asserts (ast test-name assertion-expr)
  (begin
   (defn patch-assert (_ast_)
     (if (eq? (car _ast_) 'assert)
	 (begin
	  (define body (cdr _ast_))
	  (define expr (car body))
	  (define messages (cdr body))

	  (define q-str 'quote)
	  ;(assert test-exp
	  ;	  (quote test:)
	  ;	  (quote test-name)
	  ;	  (quote expression:)
	  ;	  (quote assertion-expr)
	  ;	  messages..)

	  (concat (list 'assert
			assertion-expr
			(list q-str 'test:)
			(list q-str test-name)
			(list q-str 'expression:)
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
	      (print (green 'PASS) name)))))

