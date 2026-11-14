;; libuv binding table (define-library). Load after src/lib/ffi.lisp.
(load "src/lib/ffi.lisp")

(define-library uv ("/opt/homebrew/lib/libuv.dylib" "libuv.dylib" "libuv.so.1")
  (constant UV_RUN_DEFAULT 0)
  (constant UV_TCP 6)
  (constant UV_CONNECT 3)
  (constant UV_WRITE 2)
  (function uv_default_loop () pointer)
  (function uv_loop_size () int)
  (function uv_version () int)
  (function uv_run ((loop pointer) (mode int)) int)
  (function uv_handle_size ((klass int)) int)
  (function uv_req_size ((klass int)) int)
  (function uv_strerror ((err int)) string)
  (function uv_tcp_init ((loop pointer) (tcp pointer)) int)
  (function uv_tcp_bind ((tcp pointer) (addr pointer) (flags uint)) int)
  (function uv_listen ((handle pointer) (backlog int) (cb pointer)) int)
  (function uv_accept ((server pointer) (client pointer)) int)
  (function uv_read_start ((stream pointer) (alloc pointer) (read pointer)) int)
  (function uv_write ((req pointer) (stream pointer) (bufs pointer) (nbuf uint) (cb pointer)) int)
  (function uv_tcp_connect ((req pointer) (tcp pointer) (addr pointer) (cb pointer)) int)
  (function uv_close ((handle pointer) (cb pointer)) void)
  (function uv_ip4_addr ((ip string) (port int) (addr pointer)) int))

;; Sizes from the linked libuv (not hardcoded); zero when the library did not open.
(define UV_LOOP_BYTES (if uv-lib (uv_loop_size) 0))
(define UV_TCP_BYTES (if uv-lib (uv_handle_size UV_TCP) 0))
(define UV_CONNECT_BYTES (if uv-lib (uv_req_size UV_CONNECT) 0))
(define UV_WRITE_BYTES (if uv-lib (uv_req_size UV_WRITE) 0))

(defn uv-buf-fill (buf-ptr base len)
  (begin (ffi-poke buf-ptr 8 base) (ffi-poke (+ buf-ptr 8) 8 len)))

(defn uv-sockaddr (ip port)
  (begin
    (define p (ffi-malloc 16))
    (uv_ip4_addr ip port p)
    p))

(defn uv-make-tcp (loop)
  (begin (define p (ffi-malloc UV_TCP_BYTES)) (uv_tcp_init loop p) p))

(defn uv-make-connect-req () (ffi-malloc UV_CONNECT_BYTES))

(defn uv-make-write-req () (ffi-malloc UV_WRITE_BYTES))