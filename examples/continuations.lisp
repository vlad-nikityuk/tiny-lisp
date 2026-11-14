;; A continuation saved in one top-level form and invoked from the next (run: ./tinylisp -f examples/continuations.lisp).
(define box (list #f))
(+ 1 (call/cc (lambda (k) (begin (vset! box 0 k) 1))))
((at box 0) 10)