;; Teaching: bind a TCP handle on loopback (no listen). Requires libuv; load src/lib/uv.lisp first.
(load "src/lib/uv.lisp")
(if (not uv-lib) (error "libuv not found"))
(define *loop* (uv_default_loop))
(define *tcp* (uv-make-tcp *loop*))
(assert (eq? 0 (uv_tcp_bind *tcp* (uv-sockaddr "127.0.0.1" 19877) 0)))
(print "bound")