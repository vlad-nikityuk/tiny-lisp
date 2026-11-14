;; FFI DSL helpers: marshaling and ffi-build-call. Library bindings are written by hand or generated;
;; use (ffi-cstr "name") for dlsym so the Lisp function name can differ from the C symbol.
;; In this dialect use nil for an empty list value; bare () in argument position is invalid.

;; Top-level FFI wrappers must not be VM-inlined into callers (genInline); a one-value closure keeps env off root.
(defn ffi-no-inline (fn)
  ((lambda (_) fn) 0))

(defn cadr (x) (car (cdr x)))
(defn caddr (x) (car (cdr (cdr x))))

(defn ffi-sign-extend32 (x)
  (if (>= x 2147483648) (- x 4294967296) x))

(defn ffi-marshal-out-int (ty v)
  (if (eq? ty 'int32) (ffi-sign-extend32 (mod v 4294967296)) v))

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

(define *ffi-acc* nil)

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
    (set! *ffi-acc* (ffi-build-call-accum (if (eq? tagged nil) nil tagged) nil nil nil))
    (define r (ffi-call-typed ptr ret (car *ffi-acc*) (car (cdr *ffi-acc*))))
    (ffi-free-temps (car (cdr (cdr *ffi-acc*))))
    r))

(define ffi-build-call (ffi-no-inline ffi-build-call-impl))