(load "src/lib/node.lisp")

(define NODE_TEST_ROOT (+ "/tmp/tinylisp-node-" (getpid) "-spec"))
(if (not (fs-exists? NODE_TEST_ROOT)) (fs-mkdir NODE_TEST_ROOT))

(defn node-spec-cleanup ()
  (each (fs-read-dir NODE_TEST_ROOT)
       (fn (name)
         (define child (path-join NODE_TEST_ROOT name))
         (try (lambda () (fs-unlink child))
              (lambda (e) (try (lambda () (fs-rmdir child)) (lambda (e2) nil))))))
  (try (lambda () (fs-rmdir NODE_TEST_ROOT)) (lambda (e) nil)))

(deftest "node: path helpers"
  (assert (eq? "a/b" (path-join "a" "b")))
  (assert (eq? "a/b/c" (path-join "a" "b" "c")))
  (assert (eq? "file.txt" (path-basename "/tmp/file.txt")))
  (assert (eq? "/tmp" (path-dirname "/tmp/file.txt")))
  (assert (eq? ".txt" (path-extname "/tmp/file.txt"))))

(deftest "node: fs read write append"
  (define p (path-join NODE_TEST_ROOT "rw.txt"))
  (fs-write-file p "hello")
  (assert (fs-exists? p))
  (assert (eq? 5 (fs-stat-size p)))
  (assert (eq? "hello" (fs-read-file p)))
  (fs-append-file p " world")
  (assert (eq? "hello world" (fs-read-file p))))

(deftest "node: fs mkdir rename unlink readdir"
  (define sub (path-join NODE_TEST_ROOT "sub"))
  (fs-mkdir sub)
  (define f (path-join sub "one"))
  (fs-write-file f "x")
  (define renamed (path-join sub "two"))
  (fs-rename f renamed)
  (assert (not (fs-exists? f)))
  (define names (fs-read-dir sub))
  (assert (equal? (list "two") names))
  (fs-unlink renamed)
  (fs-rmdir sub))

(deftest "node: process and os"
  (assert (> process-pid 0))
  (assert (not (eq? "" (process-cwd))))
  (assert (process-env "PATH"))
  (assert (not (eq? "" (os-hostname))))
  (assert (eq? (process-env "HOME") (os-homedir)))
  (define t0 (process-hrtime))
  (sleep-ms 5)
  (define t1 (process-hrtime))
  (assert (if (> (car t1) (car t0)) #t (> (cadr t1) (cadr t0)))))

(run-tests)
(node-spec-cleanup)