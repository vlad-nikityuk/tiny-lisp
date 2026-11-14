;; Teaching server: binds loopback, answers one GET with \"hello\", then exits. Pair with uv-client.lisp.
(load "src/lib/uv.lisp")
(if (not uv-lib) (error "libuv not found"))

(define PORT 19877)
(define *loop* (uv_default_loop))
(define *addr* (uv-sockaddr "127.0.0.1" PORT))
(define *server* (uv-make-tcp *loop*))
(define remaining 3)
(define RESP (ffi-cstr "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"))
(define RESP-LEN 61)

(defn noop (_a _b _c _d) 0)
(define noop-cb (ffi-callback-ptr (ffi-register-callback noop)))

(defn on-alloc (_h size buf-ptr)
  (begin (define b (ffi-malloc size)) (uv-buf-fill buf-ptr b size) b))

(define alloc-cb (ffi-callback-ptr (ffi-register-callback on-alloc)))

(defn on-read (stream nread _buf)
  (if (>= nread 4)
    (begin
      (define wreq (uv-make-write-req))
      (define wb (ffi-malloc 16))
      (uv-buf-fill wb RESP RESP-LEN)
      (uv_write wreq stream wb 1 noop-cb)
      (set! remaining (- remaining 1))
      (if (eq? remaining 0) (uv_close stream noop-cb)))))

(define read-cb (ffi-callback-ptr (ffi-register-callback on-read)))

(defn on-accept (srv st)
  (if (eq? st 0)
    (begin
      (define peer (uv-make-tcp *loop*))
      (uv_accept srv peer)
      (uv_read_start peer alloc-cb read-cb))))

(define accept-cb (ffi-callback-ptr (ffi-register-callback on-accept)))

(assert (eq? 0 (uv_tcp_bind *server* *addr* 0)))
(assert (eq? 0 (uv_listen *server* 8 accept-cb)))
(uv_run *loop* UV_RUN_DEFAULT)
(print "done")