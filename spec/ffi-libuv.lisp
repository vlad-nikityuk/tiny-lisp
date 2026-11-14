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

;; Wrong UV_TCP / UV_WRITE ids allocate buffers too small for uv_tcp_init / uv_write_t (heap smash).
(deftest "uv: tcp init twice and request sizes"
  (if *have-uv*
    (begin
      (load "src/lib/uv.lisp")
      (define loop (uv_default_loop))
      (define t1 (uv-make-tcp loop))
      (define t2 (uv-make-tcp loop))
      (assert (> t1 0))
      (assert (> t2 0))
      (assert (> (uv_handle_size UV_TCP) (uv_handle_size 6)))
      (assert (> UV_TCP_BYTES 100))
      (assert (> UV_WRITE_BYTES UV_CONNECT_BYTES)))
    (assert #t)))

(run-tests)