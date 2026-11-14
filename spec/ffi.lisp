;; FFI: libc/libSystem only (portable). libuv tests live in spec/ffi-libuv.lisp.
(deftest "ffi: strlen round trip"
  (define libc (ffi-dlopen-self))
  (define strlen (ffi-dlsym libc "strlen"))
  (define s (ffi-cstr "hello"))
  (assert (= 5 (ffi-call-i64 strlen (list s) ()))))
(deftest "ffi: getpid"
  (define libc (ffi-dlopen-self))
  (define getpid (ffi-dlsym libc "getpid"))
  (assert (> (ffi-call-i64 getpid () ()) 0)))
(deftest "ffi: getenv"
  (define libc (ffi-dlopen-self))
  (define getenv (ffi-dlsym libc "getenv"))
  (define path (ffi-cstr "PATH"))
  (define p (ffi-call-i64 getenv (list path) ()))
  (assert (> p 0))
  (assert (> (string-length (ffi-string-at p)) 0)))
(deftest "ffi: libm sqrt and mixed args"
  (define libm (ffi-dlopen "libm.dylib"))
  (if libm
    (begin
      (define sqrt (ffi-dlsym libm "sqrt"))
      (define r (ffi-call-f64 sqrt (list 4) (list)))
      (assert (< (abs (- r 2)) 1e-9))
      (ffi-dlclose libm))
    (begin
      (define libm2 (ffi-dlopen "libm.so.6"))
      (assert libm2)
      (define sqrt (ffi-dlsym libm2 "sqrt"))
      (define r (ffi-call-f64 sqrt () (list 9)))
      (assert (< (abs (- r 3)) 1e-9))
      (ffi-dlclose libm2))))
(deftest "ffi: peek poke i32 negative"
  (define p (ffi-malloc 4))
  (ffi-poke p 4 -42)
  (assert (= -42 (ffi-peek p 4 #t)))
  (ffi-free p))