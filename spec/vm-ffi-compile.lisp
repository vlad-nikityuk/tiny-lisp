;; Regression: many FFI root lambdas and ffi-build-call without ffi-no-inline (GC during marshaling).
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
(deftest "vm: genInline skips ffi-build-call callees"
  (define acc (lambda (tagged) (ffi-build-call strlen-ptr 'int tagged)))
  (define outer (lambda (s) (acc (list (list s 'string)))))
  (assert (eq? 3 (outer "foo"))))

(run-tests)