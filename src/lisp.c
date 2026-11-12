#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
enum { NIL, BOOL, NUM, SYM, LIT, LIST, FN, LAM, ENV }; // SYM: symbol or runtime string, LIT: string literal from source
typedef struct V { int t; union { int b; double n; const char *s; struct Lst *l; struct Fn *f; struct Lam *lam; }; } V; typedef struct Lst { int n; V a[]; } Lst;
typedef struct Fn { V (*f)(struct Fn *, V *, int); V d0, d1; int i; } Fn; // native fn + captured data
typedef struct Env { struct Env *p; int n, cap; const char **k; V *v; } Env; typedef struct Lam { V params, body; Env *env; } Lam;
#define PTR(v) ((v).t >= SYM && (v).t <= LAM ? (void *)(v).s : 0)
#include "gc.c" // memory management: heap reference counts + per-call allocation regions
#define ARG(i) ((i) < n ? a[i] : NIL_V)
#define SPACE(c) ((c) == ' ' || (c) == '\t' || (c) == '\n' || (c) == '\r')
static const V NIL_V = {NIL}; static V errv; static jmp_buf *jb; static int in_macro, nmacros; static const char *macros[64], *hk[1 << 13]; static V hv[1 << 13];
static V sym(const char *s) { return (V){SYM, .s = s}; } static V RV(V v) { ret(PTR(v)); return v; } // RV: a heap reference to v is being stored
static char *mkstr(const char *s, size_t n, int perm) { char *t = perm ? gc_perm(n + 1) : gc_alloc(n + 1, SYM); memcpy(t, s, n); t[n] = 0; return t; }
static V fail(V e) { errv = e; longjmp(*jb, 1); } static V own(char *m) { V v = sym(mkstr(m, strlen(m), 0)); free(m); return v; } // own: malloc'd C string -> lisp string
static V list(V *a, int n) { Lst *l = gc_alloc(sizeof(Lst) + n * sizeof(V), LIST); l->n = n; for (int i = 0; i < n; i++) l->a[i] = a ? RV(a[i]) : NIL_V; return (V){LIST, .l = l}; }
static Fn *nf(V (*f)(Fn *, V *, int), V d0, V d1) { Fn *r = gc_alloc(sizeof(Fn), FN); *r = (Fn){f, RV(d0), RV(d1)}; return r; }
static int truthy(V v) { return v.t == NIL ? 0 : v.t == BOOL ? v.b : v.t == NUM ? v.n != 0 && v.n == v.n : v.t == SYM ? *v.s != 0 : 1; } static int is_nil(V v) { return v.t == NIL || (v.t == LIST && !v.l->n); }
static int eq(V a, V b) { if (is_nil(a) || is_nil(b)) return is_nil(a) && is_nil(b); if (a.t != b.t) return 0;
    return a.t == BOOL ? a.b == b.b : a.t == NUM ? a.n == b.n : a.t == SYM || a.t == LIT ? !strcmp(a.s, b.s) : a.t == LIST ? a.l == b.l : a.t == FN ? a.f == b.f : a.lam == b.lam; }
static double num(V v) { return v.t == NUM ? v.n : v.t == BOOL ? v.b : v.t == NIL ? 0 : 0.0 / 0.0; }
static void pr(FILE *f, V v) { struct { Lst *l; int i; } *st = 0; int sn = 0, cap = 0; // iterative: nested lists can't overflow the C stack
    for (;;) { switch (v.t) { case NIL: fputs("nil", f); break; case BOOL: fputs(v.b ? "#t" : "#f", f); break; case SYM: fputs(v.s, f); break; case LIT: fprintf(f, "\"%s\"", v.s); break;
    case NUM: { char b[32]; if (v.n == (long long)v.n) snprintf(b, 32, "%.0f", v.n); else for (int p = 1; p <= 17; p++) { snprintf(b, 32, "%.*g", p, v.n); if (strtod(b, 0) == v.n) break; } fputs(b, f); break; } // shortest round-trip
    case LIST: st = grow(st, &cap, sn + 1, sizeof *st); st[sn].l = v.l; st[sn++].i = 0; fputc('(', f); break; default: fputs("<function>", f); }
      for (;;) { if (!sn) { free(st); return; } if (st[sn - 1].i < st[sn - 1].l->n) { if (st[sn - 1].i) fputc(' ', f); v = st[sn - 1].l->a[st[sn - 1].i++]; break; } fputc(')', f); sn--; } } }
static char *show(V v) { char *b; size_t n; FILE *f = open_memstream(&b, &n); pr(f, v); fclose(f); return b; } // malloc'd, caller frees
static V err(const char *fmt, const char *arg) { char *b; size_t n; FILE *f = open_memstream(&b, &n); fprintf(f, fmt, arg); fclose(f); return own(b); }
static const char *P; static void skip(void) { for (;;) { while (SPACE(*P)) P++; if (*P != ';') return; while (*P && *P != '\n') P++; } }
static V atom(void) { if (*P == '"') { const char *s = ++P; while (*P && *P != '"') P++; V v = {LIT, .s = mkstr(s, P - s, 1)}; if (*P) P++; return v; } // symbols and literals are permanent
    const char *s = P; while (*P && !SPACE(*P) && !strchr("()';\"", *P)) P++; char *t = mkstr(s, P - s, 1), *end; double d = strtod(t, &end); return !*end && strpbrk(t, "0123456789") ? (V){NUM, .n = d} : sym(t); }
V parse(const char *src) { V *b = 0, d; int *open = 0, n = 0, bc = 0, sn = 0, oc = 0; P = src; // iterative: open[] = where each unfinished list starts in b[] (negative: a pending quote)
    for (;;) { skip(); if (!*P) fail(err("ToyLisp: Syntax error, %s", "unbalanced expression"));
      if (*P == '(' || *P == '\'') { open = grow(open, &oc, sn + 1, sizeof(int)); open[sn++] = *P++ == '(' ? n : -n - 1; continue; }
      if (*P == ')') { P++; if (!sn || open[sn - 1] < 0) fail(err("ToyLisp: Syntax error, %s", "unexpected closing parenthesis")); int s = open[--sn]; d = list(b + s, n - s); n = s; } else d = atom();
      while (sn && open[sn - 1] == -n - 1) { V q[2] = {sym(mkstr("quote", 5, 1)), d}; d = list(q, 2); sn--; } b = grow(b, &bc, n + 1, sizeof(V)); b[n++] = d; if (!sn) break; }
    skip(); if (*P) fail(err("ToyLisp: Syntax error, %s", "unexpected closing parenthesis")); free(open); d = b[0]; free(b); return d; }
static V *slot(Env *e, const char *k, int create) { // root scope: global hash table; lambda scopes: small arrays
    if (!e->p) { unsigned h = 2166136261u; for (const char *c = k; *c; c++) h = (h ^ (unsigned char)*c) * 16777619u;
        for (h &= (1 << 13) - 1; hk[h] && strcmp(hk[h], k); h = (h + 1) & ((1 << 13) - 1)) {} if (!hk[h] && !create) return 0; if (!hk[h]) hk[h] = k; return &hv[h]; }
    for (int i = e->n - 1; i >= 0; i--) if (e->k[i] == k || !strcmp(e->k[i], k)) return &e->v[i];
    if (!create) return 0; if (e->n == e->cap) { V *v2 = gc_raw((e->cap *= 2) * (sizeof(V) + sizeof(char *))); const char **k2 = (const char **)(v2 + e->cap); // keys follow values
        memcpy(v2, e->v, e->n * sizeof(V)); memcpy(k2, e->k, e->n * sizeof(char *)); if (e->v != (V *)(e + 1)) gc_raw_free(e->v); e->v = v2; e->k = k2; } e->k[e->n] = k; e->v[e->n] = NIL_V; return &e->v[e->n++]; }
static const char *name(V v) { return v.t == SYM ? v.s : own(show(v)).s; } V get(Env *e, const char *k) { for (; e; e = e->p) { V *s = slot(e, k, 0); if (s) return *s; } return NIL_V; }
void set(Env *e, const char *k, V v) { V *s = slot(e, k, 0); // root keys are copied to permanent memory; scope keys are counted references
    if (!s) { if (e->p) ret((void *)k); else { k = mkstr(k, strlen(k), 1); if (!strncmp(k, "macro/", 6)) macros[nmacros++] = k; } s = slot(e, k, 1); } rel(PTR(*s)); *s = RV(v); }
static Env *env_new(Env *p, int cap) { cap = cap < 4 ? 4 : cap; Env *e = p ? gc_alloc(sizeof(Env) + cap * (sizeof(V) + sizeof(char *)), ENV) : gc_perm(sizeof(Env)); // arrays inline
    ret(p); *e = (Env){p, 0, cap, (const char **)((V *)(e + 1) + cap), (V *)(e + 1)}; return e; }
static Env *bind(Lam *f, V *a, int n) { int m = f->params.t == LIST ? f->params.l->n : 0; Env *e = env_new(f->env, m);
    for (int i = 0; i < m; i++) { ret((void *)(e->k[i] = name(f->params.l->a[i]))); e->v[i] = RV(ARG(i)); } e->n = m; return e; }
typedef struct K { int kind, i, base; size_t mark; V l; Env *e; } K; // pending work: 0 if, 1 begin, 2 define/set!, 3 application
V eval(V x, Env *e); static K *ks; static int kn, kcap, vn, vcap, depth; static V *vs; // frame + operand stacks live on the heap: Lisp recursion never grows the C stack
V call(V f, V *a, int n) { if (f.t == FN) return f.f->f(f.f, a, n); if (f.t != LAM) return fail(err("ToyLisp: %s is not a function", show(f)));
    size_t m = gc_mark(); return gc_sweep(m, eval(f.lam->body, bind(f.lam, a, n)), 0); }
static V expand(V x, Env *e) { if (in_macro) return x; while (e->p) e = e->p; // every `macro/*` in the root scope sees every node before it's evaluated
    for (int i = 0; i < nmacros; i++) { in_macro = 1; V y = call(get(e, macros[i]), &x, 1); in_macro = 0; if (truthy(y)) x = y; } return x; }
V eval(V x, Env *e) { size_t m0 = gc_mark(); int base = kn; V v; if (++depth > 12000) fail(err("ToyLisp: recursion too deep%s", " (over 12000 nested calls made by native functions)")); // natives calling back (map, try, ...) re-enter eval on the C stack
ev: x = expand(x, e); if (x.t == SYM) { v = get(e, x.s); goto ret; } if (x.t == LIT) { v = sym(x.s); goto ret; } if (x.t != LIST) { v = x; goto ret; }
    { V *a = x.l->a; int n = x.l->n; if (!n) fail(err("ToyLisp: cannot evaluate an empty list%s", "")); const char *h = a[0].t == SYM ? a[0].s : ""; if (!strcmp(h, "quote")) { v = ARG(1); goto ret; }
      if (!strcmp(h, "lambda")) { Lam *f = gc_alloc(sizeof(Lam), LAM); *f = (Lam){RV(ARG(1)), RV(ARG(2)), e}; ret(e); v = (V){LAM, .lam = f}; goto ret; } if (!strcmp(h, "begin") && n < 3) { if (n == 1) { v = NIL_V; goto ret; } x = a[1]; goto ev; }
      int kind = !strcmp(h, "if") ? 0 : !strcmp(h, "begin") ? 1 : !strcmp(h, "define") || !strcmp(h, "set!") ? 2 : 3; ks = grow(ks, &kcap, kn + 1, sizeof(K));
      ks[kn++] = (K){kind, kind == 3 ? 0 : kind == 2 ? 2 : 1, vn, gc_mark(), x, e}; x = a[ks[kn - 1].i]; goto ev; }
ret: for (;;) { if (kn == base) { depth--; return gc_sweep(m0, v, 0); }
      K *k = &ks[kn - 1]; v = gc_sweep(k->mark, v, 0); V *a = k->l.l->a; int n = k->l.l->n; e = k->e;
      if (k->kind == 0) { kn--; x = truthy(v) ? ARG(2) : ARG(3); goto ev; } // tail position: no frame
      if (k->kind == 1) { if (++k->i == n - 1) kn--; else k->mark = gc_mark(); x = a[k->i]; goto ev; }
      if (k->kind == 2) { kn--; const char *s = name(a[1]); if (a[0].s[0] == 'd') set(e, s, v); else for (Env *p = e; p; p = p->p) if (slot(p, s, 0)) { set(p, s, v); break; } continue; }
      if (!k->i && v.t == NIL) fail(err("ToyLisp: Function %s is not defined", show(a[0]))); vs = grow(vs, &vcap, vn + 1, sizeof(V)); vs[vn++] = v; if (++k->i < n) { k->mark = gc_mark(); x = a[k->i]; goto ev; }
      V f = vs[k->base], sm[16], *args = n > 17 ? xrealloc(0, (n - 1) * sizeof(V)) : sm; memcpy(args, vs + k->base + 1, (n - 1) * sizeof(V)); vn = k->base; kn--; // copy: natives may re-enter eval and grow vs
      if (f.t != LAM) { v = call(f, args, n - 1); if (args != sm) free(args); continue; } e = bind(f.lam, args, n - 1); if (args != sm) free(args); x = f.lam->body; size_t *mk = kn > base ? &ks[kn - 1].mark : &m0; *mk = gc_resweep(*mk, x, e); goto ev; } } // tail call: only x and e stay live
static V binop(int op, V x, V y) { double a = num(x), b = num(y); switch (op) {
    case 0: if (x.t == SYM || x.t == LIT || y.t == SYM || y.t == LIT) { char *s = show(x), *t = show(y); size_t i = strlen(s), j = strlen(t); char *r = gc_alloc(i + j + 1, SYM);
        memcpy(r, s, i); memcpy(r + i, t, j + 1); free(s); free(t); return sym(r); } return (V){NUM, .n = a + b};
    case 1: return (V){NUM, .n = a - b}; case 2: return (V){NUM, .n = a * b}; case 3: return (V){NUM, .n = a / b}; case 4: return (V){BOOL, .b = a > b}; case 5: return (V){BOOL, .b = a < b};
    case 6: return (V){BOOL, .b = a >= b}; case 7: return (V){BOOL, .b = a <= b}; case 8: return truthy(x) ? y : x; default: return truthy(x) ? x : y; } }
static V arith(Fn *s, V *a, int n) { V r = ARG(0); for (int i = 1; i < n; i++) r = binop(s->i, r, a[i]); return r; }
static V eq_(Fn *s, V *a, int n) { for (int i = 1; i < n; i++) if (!eq(a[i], a[0])) return (V){BOOL, .b = 0}; return (V){BOOL, .b = 1}; }
static Lst *ls(V v) { static Lst empty; return v.t == LIST ? v.l : &empty; }
static V car(Fn *s, V *a, int n) { Lst *l = ls(ARG(0)); return l->n ? l->a[0] : NIL_V; } static V cdr(Fn *s, V *a, int n) { Lst *l = ls(ARG(0)); return l->n ? list(l->a + 1, l->n - 1) : list(0, 0); }
static V len(Fn *s, V *a, int n) { return (V){NUM, .n = ls(ARG(0))->n}; } static V list_(Fn *s, V *a, int n) { return list(a, n); } static V error_(Fn *s, V *a, int n) { return fail(ARG(0)); }
static V cons(Fn *s, V *a, int n) { Lst *l = ls(ARG(1)); V r = list(0, l->n + 1); r.l->a[0] = RV(ARG(0)); for (int i = 0; i < l->n; i++) r.l->a[i + 1] = RV(l->a[i]); return r; }
static V try_(Fn *s, V *a, int n) { jmp_buf j, *old = jb; int im = in_macro, k0 = kn, v0 = vn, d0 = depth; jb = &j; // on error, drop the frames of the aborted evaluation
    if (!setjmp(j)) { V r = call(ARG(0), 0, 0); jb = old; return r; } jb = old; in_macro = im; kn = k0; vn = v0; depth = d0; V e = errv; return call(ARG(1), &e, 1); }
static V thunk(Fn *s, V *a, int n) { return call(s->d0, s->d1.l->a, s->d1.l->n); } // trampoline: nested calls while active return thunks, the outermost runs them
static V tramp_run(Fn *s, V *a, int n) { if (s->i) return (V){FN, .f = nf(thunk, s->d0, list(a, n))};
    size_t m = gc_mark(); s->i = 1; V r = call(s->d0, a, n); while (r.t == FN || r.t == LAM) m = gc_resweep(m, r = call(r, 0, 0), 0); s->i = 0; return r; }
static V trampoline(Fn *s, V *a, int n) { return (V){FN, .f = nf(tramp_run, ARG(0), NIL_V)}; }
void def(Env *e, const char *k, V (*f)(Fn *, V *, int)) { set(e, k, (V){FN, .f = nf(f, NIL_V, NIL_V)}); }
Env *top_level(void) { Env *e = env_new(0, 0); const char *ops[] = {"+", "-", "*", "/", ">", "<", ">=", "<=", "&&", "||"};
    set(e, "nil", NIL_V); set(e, "#t", (V){BOOL, .b = 1}); set(e, "#f", (V){BOOL, .b = 0}); for (int i = 0; i < 10; i++) { Fn *f = nf(arith, NIL_V, NIL_V); f->i = i; set(e, ops[i], (V){FN, .f = f}); }
    def(e, "eq?", eq_); def(e, "car", car); def(e, "cdr", cdr); def(e, "len", len); def(e, "cons", cons); def(e, "list", list_); def(e, "error", error_); def(e, "try", try_); def(e, "trampoline", trampoline); return e; }
#include "stdlib_native.c"
static void load(Env *e, const char *path) { FILE *f = fopen(path, "rb"); if (!f) fail(err("cannot open %s", path)); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *s = malloc(n + 10); memcpy(s, "(begin ", 7); s[7 + fread(s + 7, 1, n, f)] = 0; fclose(f); V x = parse(strcat(s, "\n)")); free(s); eval(x, e); gc_sweep(0, NIL_V, 0); }
int main(int argc, char **argv) { Env *e = top_level(); const char *file = 0; jmp_buf j; jb = &j;
    for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "--debug")) { set(e, "*DEBUG*", (V){BOOL, .b = 1}); puts("\x1b[33mDebug mode enabled\x1b[39m"); } if (!strcmp(argv[i], "-f") && i + 1 < argc) file = argv[i + 1]; }
    if (setjmp(j)) { fprintf(stderr, "\x1b[31m%s\x1b[39m\n", show(errv)); exit(1); }     install_stdlib_native(e); load(e, "src/stdlib.lisp"); if (file) { load(e, file); return 0; }
    char *line = 0; size_t cap = 0; for (printf("#> "), fflush(stdout); getline(&line, &cap, stdin) > 0; gc_sweep(0, NIL_V, 0), printf("#> "), fflush(stdout)) { char *s = line; while (SPACE(*s)) s++;
        if (*s) { char *out = 0; if (!setjmp(j)) printf("\x1b[32m%s\x1b[39m\n", out = show(eval(parse(s), e))); else { in_macro = 0; kn = vn = depth = 0; printf("\x1b[31m%s\x1b[39m\n", out = show(errv)); } free(out); } } return 0; }
