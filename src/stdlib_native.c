// Native part of the stdlib (installed before src/stdlib.lisp is loaded). Included by lisp.c.
#include <math.h>
static V print_(Fn *s, V *a, int n) { for (int i = 0; i < n; i++) { char *t = show(a[i]); printf(i ? " %s" : "%s", t); free(t); } putchar('\n'); return NIL_V; }
static V is_list(Fn *s, V *a, int n) { return (V){BOOL, .b = ARG(0).t == LIST}; }
static V at(Fn *s, V *a, int n) { Lst *l = ls(ARG(0)); double i = num(ARG(1)); return i >= 0 && i < l->n ? l->a[(int)i] : NIL_V; }
static V map_(Fn *s, V *a, int n) {
    Lst *l = ls(ARG(0)); V r = list(0, l->n);
    for (int i = 0; i < l->n; i++) r.l->a[i] = RV(call(ARG(1), &l->a[i], 1)); // results are stored in the heap: count them
    return r;
}
static V reduce_(Fn *s, V *a, int n) {
    Lst *l = ls(ARG(0)); V m = ARG(2);
    for (int i = 0; i < l->n; i++) { V args[2] = {m, l->a[i]}; m = call(ARG(1), args, 2); }
    return m;
}
static V color(const char *code, V v) { char *b, *t = show(v); size_t n; FILE *f = open_memstream(&b, &n); fprintf(f, "\x1b[%sm%s\x1b[39m", code, t); fclose(f); free(t); return own(b); }
static V red(Fn *s, V *a, int n) { return color("31", ARG(0)); }
static V green(Fn *s, V *a, int n) { return color("32", ARG(0)); }
static V partial_run(Fn *s, V *a, int n) {
    Lst *pre = ls(s->d1); V *args = xrealloc(0, (pre->n + n + 1) * sizeof(V)); // heap, not a VLA: the prefix list can be large
    memcpy(args, pre->a, pre->n * sizeof(V)); memcpy(args + pre->n, a, n * sizeof(V));
    V r = call(s->d0, args, pre->n + n); free(args); return r;
}
static V partial(Fn *s, V *a, int n) { return (V){FN, .f = nf(partial_run, ARG(0), ARG(1))}; }

void install_stdlib_native(Env *e) {
    set(e, "pi", (V){NUM, .n = M_PI});
    def(e, "print", print_); def(e, "list?", is_list); def(e, "at", at); def(e, "map", map_); def(e, "reduce", reduce_);
    def(e, "red", red); def(e, "green", green); def(e, "partial", partial);
}
