;; Full HTTP loopback in one process (server + client on one loop). Smaller than a production server;
;; see uv-server.lisp and uv-client.lisp for the steps split apart.
(load "src/lib/uv.lisp")
(if (not uv-lib) (error "libuv not found"))

(define PORT 19877)
(define *loop* (uv_default_loop))
(define *server* (uv-make-tcp *loop*))
(define *client* (uv-make-tcp *loop*))
(define *addr* (uv-sockaddr "127.0.0.1" PORT))
(define done #f)

(define REQ (ffi-cstr "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"))
(define REQ-LEN 52)
(define RESP (ffi-cstr "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"))
(define RESP-LEN 61)

(defn noop (a b c d) 0)
(define noop-cb (ffi-callback-ptr (ffi-register-callback noop)))

(defn on-alloc (h size buf-ptr)
  (begin (define b (ffi-malloc size)) (uv-buf-fill buf-ptr b size) b))

(define alloc-cb (ffi-callback-ptr (ffi-register-callback on-alloc)))

(defn on-server-read (s nread buf)
  (if (>= nread 4)
    (begin
      (define wreq (uv-make-write-req))
      (define wb (ffi-malloc 16))
      (uv-buf-fill wb RESP RESP-LEN)
      (uv_write wreq s wb 1 noop-cb))))

(define server-read-cb (ffi-callback-ptr (ffi-register-callback on-server-read)))

(defn on-accept (srv st)
  (if (eq? st 0)
    (begin
      (define peer (uv-make-tcp *loop*))
      (uv_accept srv peer)
      (uv_read_start peer alloc-cb server-read-cb))))

(define accept-cb (ffi-callback-ptr (ffi-register-callback on-accept)))

(defn on-client-read (s nread buf)
  (if (>= nread 12)
    (begin (set! done #t) (uv_close s noop-cb) (uv_close *server* noop-cb))))

(define client-read-cb (ffi-callback-ptr (ffi-register-callback on-client-read)))

(defn on-client-write (req st) 0)
(define client-write-cb (ffi-callback-ptr (ffi-register-callback on-client-write)))

(defn on-connect (req st)
  (if (eq? st 0)
    (begin
      (define wb (ffi-malloc 16))
      (uv_read_start *client* alloc-cb client-read-cb)
      (uv-buf-fill wb REQ REQ-LEN)
      (uv_write (uv-make-write-req) *client* wb 1 client-write-cb))))

(define connect-cb (ffi-callback-ptr (ffi-register-callback on-connect)))

(defn uv-loopback-run ()
  (begin
    (assert (eq? 0 (uv_tcp_bind *server* *addr* 0)))
    (assert (eq? 0 (uv_listen *server* 4 accept-cb)))
    (assert (eq? 0 (uv_tcp_connect (uv-make-connect-req) *client* *addr* connect-cb)))
    (uv_run *loop* UV_RUN_DEFAULT)
    (assert done)))