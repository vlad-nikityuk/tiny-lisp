;; libuv bindings (hand marshaled). Load after src/lib/ffi.lisp.
(load "src/lib/ffi.lisp")

(define uv-lib
  (try (lambda () (ffi-dlopen "/opt/homebrew/lib/libuv.dylib"))
       (lambda (e) (try (lambda () (ffi-dlopen "libuv.so.1")) (lambda (e2) nil)))))

(define UV_TCP 6)
(define UV_CONNECT 3)
(define UV_WRITE 2)
(define UV_RUN_DEFAULT 0)

(define uv-sym (lambda (n) (ffi-dlsym uv-lib n)))

(define uv_default_loop (ffi-no-inline (lambda () (ffi-build-call (uv-sym "uv_default_loop") 'pointer nil))))
(define uv_run (ffi-no-inline (lambda (loop mode) (ffi-build-call (uv-sym "uv_run") 'int (list (list loop 'pointer) (list mode 'int))))))
(define uv_handle_size (ffi-no-inline (lambda (k) (ffi-build-call (uv-sym "uv_handle_size") 'size_t (list (list k 'int))))))
(define uv_req_size (ffi-no-inline (lambda (k) (ffi-build-call (uv-sym "uv_req_size") 'size_t (list (list k 'int))))))
(define uv_tcp_init (ffi-no-inline (lambda (loop tcp) (ffi-build-call (uv-sym "uv_tcp_init") 'int (list (list loop 'pointer) (list tcp 'pointer))))))
(define uv_tcp_bind (ffi-no-inline (lambda (tcp addr flags) (ffi-build-call (uv-sym "uv_tcp_bind") 'int (list (list tcp 'pointer) (list addr 'pointer) (list flags 'uint32))))))
(define uv_listen (ffi-no-inline (lambda (s backlog cb) (ffi-build-call (uv-sym "uv_listen") 'int (list (list s 'pointer) (list backlog 'int) (list cb 'pointer))))))
(define uv_accept (ffi-no-inline (lambda (server client) (ffi-build-call (uv-sym "uv_accept") 'int (list (list server 'pointer) (list client 'pointer))))))
(define uv_read_start (ffi-no-inline (lambda (s alloc read) (ffi-build-call (uv-sym "uv_read_start") 'int (list (list s 'pointer) (list alloc 'pointer) (list read 'pointer))))))
(define uv_write (ffi-no-inline (lambda (req stream bufs n cb) (ffi-build-call (uv-sym "uv_write") 'int (list (list req 'pointer) (list stream 'pointer) (list bufs 'pointer) (list n 'uint32) (list cb 'pointer))))))
(define uv_tcp_connect (ffi-no-inline (lambda (req tcp addr cb) (ffi-build-call (uv-sym "uv_tcp_connect") 'int (list (list req 'pointer) (list tcp 'pointer) (list addr 'pointer) (list cb 'pointer))))))
(define uv_close (ffi-no-inline (lambda (h cb) (ffi-build-call (uv-sym "uv_close") 'void (list (list h 'pointer) (list cb 'pointer))))))
(define uv_ip4_addr (ffi-no-inline (lambda (ip port addr) (ffi-build-call (uv-sym "uv_ip4_addr") 'int (list (list ip 'string) (list port 'int) (list addr 'pointer))))))

;; Handle/request sizes for libuv 1.x on macOS arm64 (check with uv_*_size if your libuv differs).
(define UV_TCP_BYTES 120)
(define UV_CONNECT_BYTES 192)
(define UV_WRITE_BYTES 96)

(define uv-buf-fill
  (ffi-no-inline
    (lambda (buf-ptr base len)
      (begin (ffi-poke buf-ptr 8 base) (ffi-poke (+ buf-ptr 8) 8 len)))))

(define uv-sockaddr
  (ffi-no-inline
    (lambda (ip port)
      (begin
        (define p (ffi-malloc 16))
        (uv_ip4_addr ip port p)
        p))))

(define uv-make-tcp
  (ffi-no-inline
    (lambda (loop)
      (begin (define p (ffi-malloc UV_TCP_BYTES)) (uv_tcp_init loop p) p))))

(define uv-make-connect-req
  (ffi-no-inline (lambda () (ffi-malloc UV_CONNECT_BYTES))))

(define uv-make-write-req
  (ffi-no-inline (lambda () (ffi-malloc UV_WRITE_BYTES))))