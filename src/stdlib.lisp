(define first car)
(define rest cdr)

;; shorthand for defining functions
;; (defn name args expr) -> (define name (lambda args expr))
;; (defn _add (a b) (+ a b))
(define macro/defn
  (lambda (ast)
    (if (eq? (first ast) "defn")
      (begin
        (define body (rest ast))
        (define name (first body))
        (define args (first (rest body)))
        (define expr (first (rest (rest body))))
        (list "define" name (list "lambda" args expr)))
      ast)))


(define patch-rec-trampoline
  ;; if list?
  ;;    if (name ..)
  ;;    -> return mapped via self
  (lambda (ast name)
    (if (list? ast)
      (if (eq? name (first ast))
        ;; ast: (a 1 2 3)
        ;; res: (lambda () (a 1 2 3))
        (list "lambda" '() ast)
        (map ast patch-rec-trampoline))
      ast)))

(defn not (x) (if x #f #t))
;; ------------- UTILS ----------------------------------------
;; (define print (js/eval "console.log"))
;; (define pi (js/eval "Math.PI"))

;; (defn trace (x) (begin (print x) x))

;; (defn pass () 0)
;; ;; ------------ LISTS ----------------------------------------
;; (defn empty? (lst) (eq? (len lst) 0))
;; (define list? (js/eval "Array.isArray"))

;; ;; (at lst idx)
;; (define at
;;   (js/eval "(function(lst,idx){ return lst[idx];})"))

;; (defn iterate (lst f)
;;   (if (not (empty? lst))
;;     (begin
;;       (f (first lst))
;;       (iterate (rest lst) f))))

;; (define map
;;   (js/eval "(function(lst,fn){ return lst.map(fn);})"))

;; (defn l/reduce (lst f memo)
;;   (if (empty? lst) memo
;;     (reduce (rest lst) f (f (first lst) memo))))

;; (defn r/reduce (lst f memo)
;;   (if (empty? lst) memo
;;     (f (first lst) (r/reduce (rest lst) f memo))))

;; (define reduce
;;   (js/eval "(function(lst,fn,memo){ return lst.reduce(fn, memo);})"))

;; ;; (and doesn't work here for some reason, using (&&
;; ;; (iterate (zip '(1 2 3) '(4 5 6)) print)
;; (defn zip (ll1 ll2)
;;   (if (&& (empty? ll1) (empty? ll2)) nil
;;     (cons
;;       (list (first ll1) (first ll2))
;; 	    (zip (rest ll1) (rest ll2)))))

;; (defn concat (l1 l2)
;;   (r/reduce l1 cons l2))

;; ;; -----------------------------------------------------------
;; ;; (define macro/trace trace)
;; ;; -----------------------------------------------------------

;; (define macro/defrec
;;   (lambda (ast)
;;     (if (eq? (first ast) "defrec")
;;       (begin
;;         (define body (rest ast))
;;         (define name (first body))
;;         (define args (first (rest body)))
;;         (define expr (patch-rec-trampoline (first (rest (rest body))) name))
;;         (list "define" name (list "trampoline" (list "lambda" args expr))))
;;       )
;;       ast))

;; ;; Linked lists
;; (defn c/cons (v lst)
;;   (lambda (f) (f v lst)))

;; (defn c/head (lst)
;;   (lst (lambda (h t) h)))

;; (defn c/tail (lst)
;;   (lst (lambda (h t) t)))

;; ;;-------------- COLORS -----------------------------------

;; (define red (js/eval "colors.red"))
;; (define green (js/eval "colors.green"))

;; ;;-------------- UNIT TESTS -----------------------------------
;; (defn assert (expr)
;;   (if (eq? #f expr)
;;     (begin
;;       (error "assertion-failed")
;;       #f)
;;     #t))

;; (define *TESTS* '())

;; (defn equal? (a1 a2)
;;   (if (&& (list? a1) (list? a2))
;;       (r/reduce (zip a1 a2) (lambda (x m)
;; 			      (begin
;; 			       (define v1 (first x))
;; 			       (define v2 (first (rest x)))
;; 			       (eq? v1 v2)))
;; 		#t)
;;     (eq? a1 a2)))

;; (define macro/xdeftest
;;   (lambda (ast)
;;     (if (eq? (first ast) "xdeftest") '(pass) ast)))

;; (define macro/deftest
;;   (lambda (ast)
;;     (if (eq? (first ast) "deftest")
;;       (begin
;;         (define body (rest ast))
;;         (define name (first body))
;;         (define test (first (rest body)))
;;         ;; test-name ; test-fn pair
;;         (define test-definition (list "list" (list "quote" name) name))
;;         (define tests-var "*TESTS*")
;;         (list (quote begin)
;;           (list "define" name (list "lambda" '() test))
;;           (list "set!" tests-var
;;             (list "concat" tests-var (list "list" test-definition)))))
;;       ast)))

;; ;;(patch-asserts (quote
;; ;; ast  (deftest failing-test (assert (eq? #f #t))))
;; ;; name (quote failing-test)
;; ;; expr (quote (+ 1 2)))
;; (defn patch-asserts (ast test-name assertion-expr)
;;   (begin
;;     (defn patch-assert (_ast_)
;;       (if (eq? (first _ast_) "assert")
;;         (begin
;;           (define body (rest _ast_))
;;           (define expr (first body))
;;           (define messages (rest body))
;;           (define q-str "quote")
;;           ;(assert test-exp
;;           ;	  (quote test:)
;;           ;	  (quote test-name)
;;           ;	  (quote expression:)
;;           ;	  (quote assertion-expr)
;;           ;	  messages..)

;;           (concat
;;             (list
;;               "assert"
;;               assertion-expr
;;               (list q-str "test:")
;;               (list q-str test-name)
;;               (list q-str "expression:")
;;               (list q-str assertion-expr))
;;             messages)
;;           _ast_)))

;;    (defn patch-rec (_ast_)
;;      (begin
;;       (define _new_ast_ (patch-assert _ast_))
;;       (if (list? _new_ast_)
;; 	      (map _new_ast_ patch-rec)
;; 	      _new_ast_)))
;;   (patch-rec ast)))

;; (defn run-tests ()
;;   (iterate *TESTS*
;; 	   (lambda (test)
;; 	     (begin
;; 	      (define name (first test))
;; 	      (define test-fn (first (rest test)))
;; 	      (test-fn)
;; 	      (print (green "PASS") name)))))

;; (defn partial (fn args)
;;   (js/bind fn (cons nil args))
