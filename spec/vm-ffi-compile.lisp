;; Regression: ffi-build-call uses a local accumulator (safe when a callback re-enters marshaling).
(load "src/lib/ffi.lisp")
(define libc (ffi-dlopen-self))
(define strlen-ptr (ffi-dlsym libc "strlen"))
(deftest "vm: many ffi-build-call wrappers compile and run"
  (define w0 (lambda (s) (ffi-build-call strlen-ptr 'int (list (list s 'string)))))
  (define w1 (lambda (s) (ffi-build-call strlen-ptr 'int (list (list s 'string)))))
  (define w2 (lambda (s) (ffi-build-call strlen-ptr 'int (list (list s 'string)))))
  (assert (eq? 1 (w0 "a")))
  (assert (eq? 1 (w1 "b")))
  (assert (eq? 2 (w2 "xy"))))
(deftest "vm: ffi-build-call may be inlined into callers"
  (define inner (lambda (s) (ffi-build-call strlen-ptr 'int (list (list s 'string)))))
  (define outer (lambda (s) (inner s)))
  (assert (eq? 3 (outer "foo"))))
(deftest "vm: ffi-build-call re-enters from an FFI callback"
  (define qsort (ffi-dlsym libc "qsort"))
  (define arr (ffi-malloc 16))
  (ffi-poke-f64 arr 2)
  (ffi-poke-f64 (+ arr 8) 1)
  (define id (ffi-register-callback
    (lambda (a b) (ffi-build-call strlen-ptr 'int (list (list "abcd" 'string))))))
  (ffi-call-void qsort (list arr 2 8 (ffi-callback-ptr id)) nil)
  (assert (eq? 4 (ffi-build-call strlen-ptr 'int (list (list "abcd" 'string)))))
  (ffi-release-callback id)
  (ffi-free arr))

(run-tests)