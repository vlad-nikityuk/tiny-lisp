;; FFI DSL helpers: marshaling and ffi-build-call. Library bindings are written by hand or generated;
;; use (ffi-cstr "name") for dlsym so the Lisp function name can differ from the C symbol.
;; In this dialect use nil for an empty list value; bare () in argument position is invalid.

(defn cadr (x) (car (cdr x)))
(defn caddr (x) (car (cdr (cdr x))))
(defn cadddr (x) (car (cdr (cdr (cdr x)))))

(defn ffi-sign-extend32 (x)
  (if (>= x 2147483648) (- x 4294967296) x))

(defn ffi-marshal-out-int (ty v)
  (if (eq? ty 'int) (ffi-sign-extend32 (mod v 4294967296))
    (if (eq? ty 'int32) (ffi-sign-extend32 (mod v 4294967296)) v)))

(defn ffi-marshal-out (ty v)
  (if (eq? ty 'string) (ffi-string-at v)
    (if (eq? ty 'bool) (not (eq? v 0))
      (if (eq? ty 'void) nil
        (ffi-marshal-out-int ty v)))))

(defn ffi-marshal-in (ty v temps)
  (if (eq? ty 'double) (list nil (list v) temps)
    (if (eq? ty 'float) (list nil (list v) temps)
      (if (eq? ty 'string)
        (begin (define p (ffi-cstr v)) (list (list p) nil (cons p temps)))
        (if (eq? ty 'callback)
          (list (list (ffi-callback-ptr (ffi-register-callback v))) nil temps)
          (list (list (if (eq? ty 'bool) (if v 1 0) v)) nil temps))))))

(defn ffi-call-typed (ptr ret ints floats)
  (if (eq? ret 'void) (begin (ffi-call-void ptr ints floats) nil)
    (if (eq? ret 'double) (ffi-marshal-out 'double (ffi-call-f64 ptr ints floats))
      (if (eq? ret 'float) (ffi-marshal-out 'float (ffi-call-f64 ptr ints floats))
        (ffi-marshal-out ret (ffi-call-i64 ptr ints floats))))))

(defn ffi-free-temps (ts)
  (if (eq? ts nil) nil
    (begin (ffi-free (car ts)) (ffi-free-temps (cdr ts)))))

(defn ffi-build-call-accum (tagged iargs fargs temps)
  (if (eq? tagged nil)
    (list iargs fargs temps)
    (begin
      (define p (car tagged))
      (define trip (ffi-marshal-in (cadr p) (car p) temps))
      (ffi-build-call-accum (cdr tagged)
                            (concat iargs (car trip))
                            (concat fargs (car (cdr trip)))
                            (car (cdr (cdr trip)))))))

(defn ffi-build-call-impl (ptr ret tagged)
  (begin
    (define acc (ffi-build-call-accum (if (eq? tagged nil) nil tagged) nil nil nil))
    (define r (ffi-call-typed ptr ret (car acc) (car (cdr acc))))
    (ffi-free-temps (car (cdr (cdr acc))))
    r))

(define ffi-build-call ffi-build-call-impl)

;; define-library DSL (single-level expansion: library-expand builds lists with cons, no nested quasiquote).
;; (define-library libc self (function strlen ((s string)) int) ...)
;; (define-library uv ("libuv.dylib" "libuv.so.1") (function uv_run ((loop pointer) (mode int)) int) ...)

(defn ffi-try-dlopen (paths)
  (if (eq? paths nil) nil
    (try (lambda () (ffi-dlopen (car paths)))
         (lambda (e) (ffi-try-dlopen (cdr paths))))))

(defn ffi-open-library (paths)
  (if (eq? paths 'self) (ffi-dlopen-self)
    (if (list? paths) (ffi-try-dlopen paths)
      (if (eq? paths nil) nil (ffi-dlopen paths)))))

(defn ffi-type-known? (ty)
  (if (list? ty) (eq? (car ty) 'callback)
    (if (eq? ty 'int) #t
      (if (eq? ty 'uint) #t
        (if (eq? ty 'int32) #t
          (if (eq? ty 'uint32) #t
            (if (eq? ty 'long) #t
              (if (eq? ty 'ulong) #t
                (if (eq? ty 'size_t) #t
                  (if (eq? ty 'pointer) #t
                    (if (eq? ty 'string) #t
                      (if (eq? ty 'double) #t
                        (if (eq? ty 'float) #t
                          (if (eq? ty 'bool) #t
                            (eq? ty 'void)))))))))))))))

(defn ffi-type-marshal (ty)
  (if (list? ty) (if (eq? (car ty) 'callback) 'callback (error "TinyLisp: unknown FFI type in DSL"))
    (if (eq? ty 'uint) 'uint32 ty)))

(defn ffi-type-ret (ty)
  (ffi-type-marshal ty))

(defn ffi-check-type (ty ctx)
  (if (not (ffi-type-known? ty)) (error (concat "TinyLisp: unknown FFI type " (list ctx)))))

(defn ffi-param-names (params)
  (if (eq? params nil) (list)
    (cons (car (car params)) (ffi-param-names (cdr params)))))

(defn ffi-tag-ast (param)
  (list "list" (car param) (list "quote" (ffi-type-marshal (cadr param)))))

(defn ffi-tags-ast (params)
  (if (eq? params nil) nil
    (if (eq? (cdr params) nil)
      (list "list" (ffi-tag-ast (car params)))
      (list "concat" (list "list" (ffi-tag-ast (car params))) (ffi-tags-ast (cdr params))))))

(defn ffi-expand-function (lib-var sym lisp-name ret params)
  (begin
    (ffi-check-type ret (concat lisp-name " return type"))
    (for (p params)
      (ffi-check-type (cadr p) (car p)))
    (list "define" lisp-name
          (list "lambda" (ffi-param-names params)
                (list "ffi-build-call"
                      (list "ffi-dlsym" lib-var (list "quote" sym))
                      (list "quote" (ffi-type-ret ret))
                      (ffi-tags-ast params))))))

(defn ffi-expand-constant (name val)
  (list "define" name val))

(defn ffi-expand-decl (lib-var decl)
  (if (not (list? decl)) (error "TinyLisp: library declaration must be a list")
    (if (eq? (car decl) "function")
      (ffi-expand-function lib-var (cadr decl) (cadr decl) (cadddr decl) (caddr decl))
      (if (eq? (car decl) "constant")
        (ffi-expand-constant (cadr decl) (caddr decl))
        (error (concat "TinyLisp: unknown library form " (list (car decl))))))))

(defn ffi-expand-library (lib-name paths decls)
  (begin
    (define lib-var (+ (if (list? lib-name) (car lib-name) lib-name) "-lib"))
    (define forms (list (list "define" lib-var (list "ffi-open-library" (list "quote" paths)))))
    (for (d decls)
      (set! forms (concat forms (list (ffi-expand-decl lib-var d)))))
    (cons "begin" forms)))

(defmacro define-library (lib-name paths & decls)
  (ffi-expand-library lib-name paths decls))