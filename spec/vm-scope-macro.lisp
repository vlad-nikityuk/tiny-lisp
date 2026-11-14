;; Regression: many nested macro expansions (defn) after heavy top-level work must not
;; corrupt the scope pool (see scope.bindWith).
(load "src/lib/uv.lisp")
(define PORT 19877)
(define *loop* (uv_default_loop))
(define *server* (uv-make-tcp *loop*))
(defn smoke0 (a) a)
(defn smoke1 (a) a)
(defn smoke2 (a) a)
(defn smoke3 (a) a)
(defn smoke4 (a) a)
(defn smoke5 (a) a)
(defn smoke6 (a) a)
(defn smoke7 (a) a)
(defn smoke8 (a) a)
(defn smoke9 (a) a)
(deftest "vm: defn after ffi top-level"
  (assert (eq? (smoke9 99) 99)))
(run-tests)