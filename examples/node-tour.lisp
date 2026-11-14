;; Small tour of src/lib/node.lisp (libc fs/path/process helpers).
(load "src/lib/node.lisp")

(define tour-root (+ "/tmp/tinylisp-node-tour-" (getpid)))
(fs-mkdir tour-root)

(define demo-file (path-join tour-root "greeting.txt"))
(fs-write-file demo-file "Hello from tinylisp node.lisp")
(print (+ "wrote " demo-file ": " (fs-read-file demo-file)))
(print (+ "cwd: " (process-cwd)))
(print (+ "pid: " process-pid))
(print (+ "hostname: " (os-hostname)))
(print (+ "entries: " (fs-read-dir tour-root)))

(fs-unlink demo-file)
(fs-rmdir tour-root)