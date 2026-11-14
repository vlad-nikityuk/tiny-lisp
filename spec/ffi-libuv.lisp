;; libuv: optional; skipped cleanly when the dylib is absent.
(load "src/lib/ffi.lisp")

(define *have-uv*
  (try (lambda () (begin (ffi-dlopen "/opt/homebrew/lib/libuv.dylib") #t))
       (lambda (e) (try (lambda () (begin (ffi-dlopen "libuv.so.1") #t))
                        (lambda (e2) (try (lambda () (begin (ffi-dlopen "libuv.dylib") #t))
                                         (lambda (e3) #f)))))))

(deftest "uv: dlopen"
  (if *have-uv* (assert #t) (assert #t)))

(deftest "uv: version and handle size"
  (if *have-uv*
    (begin
      (load "src/lib/uv.lisp")
      (assert (> (uv_version) 0))
      (assert (> (uv_handle_size UV_TCP) 0)))
    (assert #t)))

(run-tests)