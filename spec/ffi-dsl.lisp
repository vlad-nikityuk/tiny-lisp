;; define-library on libc (no libuv required)
(load "src/lib/ffi.lisp")

(define-library libc-self self
  (function strlen ((s string)) int)
  (function getpid () int))

(deftest "dsl: define-library opens self and calls strlen"
  (assert libc-self-lib)
  (assert (eq? 3 (strlen "abc"))))
(deftest "dsl: define-library getpid"
  (assert (> (getpid) 0)))

(run-tests)