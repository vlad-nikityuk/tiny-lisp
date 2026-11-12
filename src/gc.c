// Memory management: reference counts for heap references + per-call allocation regions.
//
// Only references stored in the heap are counted: list elements, scope slots, globals, closure
// captures and native-closure data. References held in C locals are not, which keeps eval free of
// inc/dec bookkeeping. Instead every allocation is appended to a log, and each eval/call remembers
// the log position when it started (gc_mark). When it finishes (gc_sweep) everything allocated
// since then with a zero count is freed, except the value being returned, which simply stays in
// the log and so becomes part of the caller's region. Scopes are ordinary objects: a scope that no
// closure captured has a zero count and is freed as soon as its call returns.
//
// Limitation: reference cycles (e.g. a closure stored in the scope it captures) are never freed.
typedef struct H { int rc; short kind, age; size_t idx; } H; // header in front of every managed object (16 bytes); age: sweeps survived
#define HDR(p) ((H *)(p) - 1)
enum { PERM = -1, DEAD = -2 };
static void *xrealloc(void *p, size_t n) { if (!(p = realloc(p, n)) && n) { fputs("ToyLisp: out of memory\n", stderr); exit(1); } return p; }
static void *grow(void *p, int *cap, int need, size_t size) { if (need > *cap) { while (need > *cap) *cap = *cap ? *cap * 2 : 64; p = xrealloc(p, (size_t)*cap * size); } return p; }
static H **gc_log, **dying; static size_t gc_n, gc_cap, sweep_from; static int ndying, dying_cap; // dying: freed via a worklist, never recursively
static H **gc_log_unused; static void *keep_a, *keep_b; static int sweeping;
static void *gc_alloc(size_t n, int kind) {
    H *h = memset(xrealloc(0, sizeof(H) + n), 0, sizeof(H) + n); h->kind = kind; h->idx = gc_n;
    if (gc_n == gc_cap) gc_log = xrealloc(gc_log, (gc_cap = gc_cap ? gc_cap * 2 : 4096) * sizeof(H *));
    gc_log[gc_n++] = h; return h + 1;
}
static void *gc_perm(size_t n) { H *h = memset(xrealloc(0, sizeof(H) + n), 0, sizeof(H) + n); h->kind = PERM; h->rc = 1 << 30; return h + 1; } // never freed
static void *gc_raw(size_t n) { return xrealloc(0, n); } // buffers owned by one object (grown scope arrays)
static void gc_raw_free(void *p) { free(p); }
static void ret(void *p) { if (p) HDR(p)->rc++; }
static void doom(H *h) { gc_log[h->idx] = 0; dying = grow(dying, &dying_cap, ndying + 1, sizeof(H *)); dying[ndying++] = h; } // queue for freeing
static void rel(void *p) { // drop a heap reference; while sweeping, objects of the region that hit zero are freed too
    if (!p) return; H *h = HDR(p);
    if (--h->rc <= 0 && sweeping && h->kind >= 0 && h->idx >= sweep_from && gc_log[h->idx] == h && p != keep_a && p != keep_b) doom(h);
}
static void rel_v(V v) { rel(PTR(v)); }
static void free_obj(H *h) {
    void *p = h + 1; int kind = h->kind; h->kind = DEAD;
    if (kind == LIST) for (int i = 0; i < ((Lst *)p)->n; i++) rel_v(((Lst *)p)->a[i]);
    if (kind == FN) { rel_v(((Fn *)p)->d0); rel_v(((Fn *)p)->d1); }
    if (kind == LAM) { Lam *l = p; rel_v(l->params); rel_v(l->body); rel(l->env); }
    if (kind == ENV) { Env *e = p; rel(e->p); for (int i = 0; i < e->n; i++) { rel((void *)e->k[i]); rel_v(e->v[i]); } if (e->v != (V *)(e + 1)) free(e->v); }
    free(h);
}
static size_t gc_mark(void) { return gc_n; }
enum { OLD = 4 }; // loop sweeps an object must survive before it's treated as long-lived (values passed along a loop live ~2)
static size_t sweep(size_t m, V keep, void *keep2, int loop) { // free everything allocated since m that nothing references (except keep/keep2)
    if (gc_n == m) return m;
    sweep_from = m; keep_a = PTR(keep); keep_b = keep2; sweeping = 1;
    for (size_t i = m; i < gc_n; i++) { H *h = gc_log[i]; if (h && h->rc <= 0 && h + 1 != keep_a && h + 1 != keep_b) doom(h); while (ndying) free_obj(dying[--ndying]); }
    sweeping = 0; size_t j = m;
    // Survivors stay in the log and so join the caller's region. In a loop (tail calls, trampoline) the same region is swept again
    // every iteration: survivors that are heap-referenced and already lived through OLD loop sweeps are long-lived, so they go first
    // and the returned mark leaves them to the enclosing region instead of rescanning them every iteration (that would be quadratic).
    for (int pass = 0; pass < 2; pass++)
        for (size_t i = m; i < gc_n; i++) { H *h = gc_log[i]; if (h && (loop && h->rc > 0 && h->age >= OLD) == !pass) { gc_log[i] = 0; h->idx = j; gc_log[j++] = h; } }
    size_t young = j; for (size_t i = m; i < j; i++) if (!(loop && gc_log[i]->rc > 0 && gc_log[i]->age >= OLD)) { young = i; break; }
    if (loop) for (size_t i = young; i < j; i++) if (gc_log[i]->age < OLD) gc_log[i]->age++;
    gc_n = j; return young;
}
static V gc_sweep(size_t m, V keep, void *keep2) { sweep(m, keep, keep2, 0); return keep; }
static size_t gc_resweep(size_t m, V keep, void *keep2) { return sweep(m, keep, keep2, 1); } // for loops: returns the mark to sweep from next time
