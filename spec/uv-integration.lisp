;; libuv binding smoke test; skipped when the library is absent.
(load "src/lib/ffi.lisp")

(define *have-uv*
  (try (lambda () (begin (ffi-dlopen "/opt/homebrew/lib/libuv.dylib") #t))
       (lambda (e) (try (lambda () (begin (ffi-dlopen "libuv.so.1") #t))
                        (lambda (e2) (try (lambda () (begin (ffi-dlopen "libuv.dylib") #t))
                                         (lambda (e3) #f)))))))

(deftest "uv: define-library binding loads"
  (if *have-uv*
    (begin
      (load "src/lib/uv.lisp")
      (assert uv-lib)
      (assert (> (uv_handle_size UV_TCP) 0)))
    (assert #t)))

(run-tests)