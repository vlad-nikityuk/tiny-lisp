;; Node.js-like libc file/process helpers (load on demand: (load "src/lib/node.lisp")).
;; macOS and Linux glibc only; struct layouts are probed once at load time.
(load "src/lib/ffi.lisp")

(define-library libc-node self
  (constant NODE_CLOCK_MONOTONIC 1)
  (constant NODE_F_OK 0)
  (function access ((path string) (mode int)) int)
  (function stat ((path string) (buf pointer)) int)
  (function mkdir ((path string) (mode uint)) int)
  (function rmdir ((path string)) int)
  (function unlink ((path string)) int)
  (function rename ((old string) (new string)) int)
  (function opendir ((path string)) pointer)
  (function readdir ((dir pointer)) pointer)
  (function closedir ((dir pointer)) int)
  (function getcwd ((buf pointer) (size size_t)) pointer)
  (function getpid () int)
  (function getenv ((name string)) pointer)
  (function exit ((code int)) void)
  (function gethostname ((buf pointer) (len size_t)) int)
  (function usleep ((usec uint)) int)
  (function strerror ((err int)) string)
  (function clock_gettime ((clk int) (tp pointer)) int)
  (function gettimeofday ((tv pointer) (tz pointer)) int))

(if (not libc-node-lib)
  (error "TinyLisp: libc-node could not open libSystem / libc"))

;; errno is a macro in C; call __errno_location / __error for a pointer to the current code.
(define node-errno-fn
  (try (lambda () (ffi-dlsym libc-node-lib "__errno_location"))
       (lambda (e) (ffi-dlsym libc-node-lib "__error"))))

(defn node-errno ()
  (ffi-peek (ffi-call-i64 node-errno-fn nil nil) 4 #t))

(defn node-io-error (op detail)
  (error (+ op ": " detail " (" (strerror (node-errno)) ")")))

(defn node-check-rc (op rc)
  (if (>= rc 0) rc (node-io-error op "system call failed")))

(defn node-check-ptr (op p)
  (if (eq? p 0) (node-io-error op "null pointer") p))

(define NODE_STAT_BUF 256)
(define NODE_PATH_MAX 4096)
(define NODE_DIRENT_PROBE "tinylisp-dirent-probe")

;; Find st_size in struct stat by stat() on a file whose size we control.
(defn node-probe-stat-off ()
  (begin
    (define path (+ "/tmp/tinylisp-node-stat-" (getpid)))
    (write-file path "012345678901234567890123456789012345678901")
    (define buf (ffi-malloc NODE_STAT_BUF))
    (define rc (stat path buf))
    (if (< rc 0) (error "TinyLisp: node stat probe failed"))
    (define off
      (reduce (map (range 16) (lambda (i) (* i 8)))
              (lambda (found o)
                (if found found
                  (if (eq? (ffi-peek (+ buf o) 8 #t) 42) o
                    (if (eq? (ffi-peek (+ buf o) 4 #t) 42) o nil))))
              nil))
    (ffi-free buf)
    (unlink path)
    (if off off (error "TinyLisp: could not find st_size offset in struct stat"))))

(defn node-dirent-scan (dir off)
  (define ent (readdir dir))
  (if (eq? ent 0) #f
    (if (eq? (ffi-string-at (+ ent off)) NODE_DIRENT_PROBE) #t
      (node-dirent-scan dir off))))

(defn node-dirent-off? (dir-path off)
  (begin
    (define dir (opendir dir-path))
    (define ok (if (eq? dir 0) #f (node-dirent-scan dir off)))
    (if (not (eq? dir 0)) (closedir dir))
    ok))

(defn node-probe-dirent-off (dir-path)
  (define off
    (reduce (list 19 20 21 22 23)
            (lambda (found candidate)
              (if found found
                (if (node-dirent-off? dir-path candidate) candidate nil)))
            nil))
  (if off off (error "TinyLisp: could not find dirent.d_name offset")))

(define NODE_STAT_SIZE_OFF (node-probe-stat-off))

(define NODE_DIRENT_NAME_OFF
  (begin
    (define probe-dir (+ "/tmp/tinylisp-node-dirent-" (getpid)))
    (mkdir probe-dir 493)
    (write-file (+ probe-dir "/" NODE_DIRENT_PROBE) "")
    (define off (node-probe-dirent-off probe-dir))
    (unlink (+ probe-dir "/" NODE_DIRENT_PROBE))
    (rmdir probe-dir)
    off))

;; --- path (pure Lisp) ---

(defn path-last (parts)
  (reduce (cdr parts) (lambda (_ x) x) (car parts)))

(defn path-join (& parts)
  (reduce parts
          (lambda (acc p)
            (if (eq? p "") acc
              (if (eq? acc "") p (+ acc "/" p))))
          ""))

(defn path-basename (p)
  (define parts (filter (split p "/") (lambda (x) (not (eq? x "")))))
  (if (eq? parts nil) "" (path-last parts)))

(defn path-absolute? (p)
  (eq? (car (split p "/")) ""))

(defn path-dirname (p)
  (define parts (filter (split p "/") (lambda (x) (not (eq? x "")))))
  (define inner (if (<= (len parts) 1) ""
                   (reduce (range (- (len parts) 1))
                           (lambda (acc i) (if (eq? acc "") (at parts i) (+ acc "/" (at parts i))))
                           "")))
  (if (path-absolute? p)
    (if (eq? inner "") "/" (+ "/" inner))
    inner))

(defn path-extname (p)
  (define base (path-basename p))
  (define parts (split base "."))
  (if (<= (len parts) 1) ""
    (+ "." (path-last parts))))

;; --- fs ---

(defn fs-exists? (path)
  (eq? (access path NODE_F_OK) 0))

(defn fs-stat-size (path)
  (begin
    (define buf (ffi-malloc NODE_STAT_BUF))
    (node-check-rc "fs-stat-size" (stat path buf))
    (define sz (ffi-peek (+ buf NODE_STAT_SIZE_OFF) 8 #t))
    (ffi-free buf)
    sz))

(defn fs-mkdir (path)
  (node-check-rc "fs-mkdir" (mkdir path 493)))

(defn fs-rmdir (path)
  (node-check-rc "fs-rmdir" (rmdir path)))

(defn fs-unlink (path)
  (node-check-rc "fs-unlink" (unlink path)))

(defn fs-rename (old new)
  (node-check-rc "fs-rename" (rename old new)))

(defn fs-read-file (path)
  (read-file path))

(defn fs-write-file (path text)
  (write-file path text))

(defn fs-append-file (path text)
  (begin
    (define prev (try (lambda () (read-file path)) (lambda (e) "")))
    (write-file path (+ prev text))))

(defn fs-read-dir-accum (dir acc)
  (define ent (readdir dir))
  (if (eq? ent 0) acc
    (begin
      (define name (ffi-string-at (+ ent NODE_DIRENT_NAME_OFF)))
      (if (eq? name ".")
        (fs-read-dir-accum dir acc)
        (if (eq? name "..")
          (fs-read-dir-accum dir acc)
          (fs-read-dir-accum dir (concat acc (list name))))))))

(defn fs-read-dir (path)
  (begin
    (define dir (node-check-ptr "fs-read-dir" (opendir path)))
    (define names (fs-read-dir-accum dir nil))
    (closedir dir)
    names))

;; --- process / os / time ---

(defn process-cwd ()
  (begin
    (define buf (ffi-malloc NODE_PATH_MAX))
    (define p (getcwd buf NODE_PATH_MAX))
    (if (eq? p 0)
      (begin (ffi-free buf) (node-io-error "process-cwd" "getcwd failed"))
      (begin (define s (ffi-string-at buf)) (ffi-free buf) s))))

(define process-pid (getpid))

(defn process-env (name)
  (begin
    (define p (getenv name))
    (if (eq? p 0) nil (ffi-string-at p))))

(defn process-exit (code)
  (exit code))

(defn process-hrtime ()
  (begin
    (define tp (ffi-malloc 16))
    (define ok (>= (clock_gettime NODE_CLOCK_MONOTONIC tp) 0))
    (if ok
      (begin
        (define sec (ffi-peek tp 8 #t))
        (define nsec (ffi-peek (+ tp 8) 8 #t))
        (ffi-free tp)
        (list sec nsec))
      (begin
        (node-check-rc "process-hrtime" (gettimeofday tp 0))
        (define sec (ffi-peek tp 8 #t))
        (define usec (ffi-peek (+ tp 8) 8 #t))
        (ffi-free tp)
        (list sec (* usec 1000))))))

(defn os-hostname ()
  (begin
    (define buf (ffi-malloc 256))
    (node-check-rc "os-hostname" (gethostname buf 256))
    (define s (ffi-string-at buf))
    (ffi-free buf)
    s))

(defn os-homedir ()
  (define h (process-env "HOME"))
  (if h h (error "TinyLisp: os-homedir: HOME is not set")))

(defn sleep-ms (ms)
  (node-check-rc "sleep-ms" (usleep (* ms 1000))))