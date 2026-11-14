;; Teaching client: one GET to 127.0.0.1:19877 (start uv-server.lisp first in another process).
(load "src/lib/uv.lisp")
(if (not uv-lib) (error "libuv not found"))

(define PORT 19877)
(define *loop* (uv_default_loop))
(define *client* (uv-make-tcp *loop*))
(define *addr* (uv-sockaddr "127.0.0.1" PORT))
(define REQ (ffi-cstr "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"))
(define REQ-LEN 52)
(define got-body #f)

(defn noop (_a _b _c _d) 0)
(define noop-cb (ffi-callback-ptr (ffi-register-callback noop)))

(defn on-alloc (_h size buf-ptr)
  (begin (define b (ffi-malloc size)) (uv-buf-fill buf-ptr b size) b))

(define alloc-cb (ffi-callback-ptr (ffi-register-callback on-alloc)))

(defn on-read (_s nread _buf)
  (if (>= nread 60)
    (begin (set! got-body #t) (uv_close *client* noop-cb))))

(define read-cb (ffi-callback-ptr (ffi-register-callback on-read)))

(defn on-write (_req st) 0)
(define write-cb (ffi-callback-ptr (ffi-register-callback on-write)))

(defn on-connect (req st)
  (if (eq? st 0)
    (begin
      (define wb (ffi-malloc 16))
      (uv_read_start *client* alloc-cb read-cb)
      (uv-buf-fill wb REQ REQ-LEN)
      (uv_write (uv-make-write-req) *client* wb 1 write-cb))))

(define connect-cb (ffi-callback-ptr (ffi-register-callback on-connect)))

(assert (eq? 0 (uv_tcp_connect (uv-make-connect-req) *client* *addr* connect-cb)))
(uv_run *loop* UV_RUN_DEFAULT)
(assert got-body)
(print "ok")