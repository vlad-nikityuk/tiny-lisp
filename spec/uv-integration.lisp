;; libuv HTTP loopback: server and client on one loop, repeated requests. Skipped when libuv is absent.
(load "src/lib/ffi.lisp")

(define *have-uv*
  (try (lambda () (begin (ffi-dlopen "/opt/homebrew/lib/libuv.dylib") #t))
       (lambda (e) (try (lambda () (begin (ffi-dlopen "libuv.so.1") #t))
                        (lambda (e2) (try (lambda () (begin (ffi-dlopen "libuv.dylib") #t))
                                         (lambda (e3) #f)))))))

(deftest "uv: HTTP loopback three times"
  (if *have-uv*
    (begin
      (load "examples/uv-loopback.lisp")
      (for (i (range 3)) (uv-loopback-run (+ 19877 i)))
      (assert done))
    (assert #t)))

(run-tests)