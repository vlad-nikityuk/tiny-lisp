// zig fmt: off
const std = @import("std"); const gc = @import("gc.zig"); const runtime = @import("runtime.zig");

// Public language API; runtime owns values, parsing, scopes, primitives and the natives that call back into Lisp.
pub const E = runtime.E; pub const V = runtime.V; pub const Lst = runtime.Lst;
pub const Fn = runtime.Fn; pub const Lam = runtime.Lam; pub const Env = runtime.Env; pub const Var = runtime.Var;
pub const ptr = runtime.ptr; pub const rv = runtime.rv; pub const arg = runtime.arg; pub const items = runtime.items;
pub const str = runtime.str; pub const list = runtime.list; pub const nf = runtime.nf; pub const num = runtime.num;
pub const parse = runtime.parse; pub const set = runtime.set; pub const topLevel = runtime.topLevel;
const lookup = runtime.lookup; const bind = runtime.bind; const fail = runtime.fail; const truthy = runtime.truthy;
pub var out: *std.Io.Writer = undefined; pub var errv: V = .nil;

// Pending work lives in heap frames, so nothing grows the native stack: not Lisp recursion, and not natives that
// call back into Lisp (map, reduce, try, ...): those are `native` frames, resumed with each callback's value.
const Form = enum { quote, lambda, @"if", begin, define, @"set!", apply, native }; // apply: anything else
pub const K = struct { kind: Form, i: usize, base: usize, mark: usize, l: []V, e: *Env };
pub const Go = union(enum) { eval: V, ret: V, apply: usize }; // apply: the function at vs[apply], then its arguments
pub var ks: std.ArrayList(K) = .empty; // frame stack
pub var vs: std.ArrayList(V) = .empty; // operand stack: function + arguments being collected, native frames' state
var in_macro = false;
const M = struct { go: Go, e: *Env, m0: usize, base: usize }; // a machine run: this eval's frames are ks[base..]

// Macro expansion is the only nested machine: macros don't expand inside macros, so it nests once.
fn call(f: V, x: V) E!V {
    const b = vs.items.len; defer vs.items.len = b; gc.push(V, &vs, f); gc.push(V, &vs, x);
    return exec(.{ .apply = b }, undefined);
}

// Run until this run's frames are done. An error resumes at the innermost `try` frame of this run, if any.
pub fn eval(node: V, env: *Env) E!V { return exec(.{ .eval = node }, env); }
fn exec(go: Go, env: *Env) E!V {
    var m: M = .{ .go = go, .e = env, .m0 = gc.mark(), .base = ks.items.len }; const vbase = vs.items.len;
    errdefer ks.items.len, vs.items.len = .{ m.base, vbase };
    while (true) return run(&m) catch |err| { m.go = runtime.recover(m.base) orelse return err; continue; };
}

// Expand and evaluate a node, feed its value through pending frames, apply functions.
fn run(m: *M) E!V {
    var e = m.e;
    sw: switch (m.go) {
        .eval => |node| {
            var x = node;
            if (!in_macro) { // every macro/* in the root scope sees every node before it's evaluated
                in_macro = true; defer in_macro = false;
                for (runtime.macros.items) |p| { const y = try call(p.*, x); if (truthy(y)) x = y; }
            }
            switch (x) {
                .s => |s| continue :sw .{ .ret = if (lookup(e, s)) |p| p.* else .nil },
                .lit => |s| continue :sw .{ .ret = .{ .s = s } },
                .l => |l| {
                    const a = l.a; if (a.len == 0) return fail(str("ToyLisp: cannot evaluate an empty list", .{}));
                    const f = if (a[0] == .s) std.meta.stringToEnum(Form, std.mem.span(a[0].s)) orelse .apply else .apply;
                    const kind = if (f == .native) .apply else f;
                    if (kind == .quote) continue :sw .{ .ret = arg(a, 1) };
                    if (kind == .lambda) continue :sw .{ .ret = runtime.lambda(a, e) };
                    const i: usize = if (kind == .apply) 0 else if (kind == .define or kind == .@"set!") 2 else 1;
                    if (kind != .begin or a.len > 2) gc.push(K, &ks, .{ .kind = kind, .i = i, .base = vs.items.len, .mark = gc.mark(), .l = a, .e = e });
                    continue :sw .{ .eval = arg(a, i) };
                },
                else => continue :sw .{ .ret = x },
            }
        },
        .ret => |r| { // hand the value to the innermost frame
            if (ks.items.len == m.base) return gc.sweepKeep(m.m0, r);
            const k = &ks.items[ks.items.len - 1];
            const v = gc.sweepKeep(k.mark, r); const a = k.l; e = k.e;
            switch (k.kind) {
                .@"if" => { ks.items.len -= 1; continue :sw .{ .eval = if (truthy(v)) arg(a, 2) else arg(a, 3) }; }, // tail position
                .begin => {
                    k.i += 1; const x = a[k.i]; if (k.i == a.len - 1) ks.items.len -= 1 else k.mark = gc.mark();
                    continue :sw .{ .eval = x };
                },
                .define, .@"set!" => { try runtime.assign(k.kind == .define, a, e, v); ks.items.len -= 1; continue :sw .{ .ret = v }; },
                .native => continue :sw try runtime.step(k, v),
                else => { // apply: collect the function and its arguments on vs
                    if (k.i == 0 and v == .nil) return fail(str("ToyLisp: Function {f} is not defined", .{a[0]}));
                    gc.push(V, &vs, v); k.i += 1;
                    if (k.i < a.len) { k.mark = gc.mark(); continue :sw .{ .eval = a[k.i] }; }
                    ks.items.len -= 1; continue :sw .{ .apply = k.base };
                },
            }
        },
        .apply => |b| { // in tail position of the innermost frame
            const f = vs.items[b]; const args = vs.items[b + 1 ..];
            switch (f) {
                .lam => |l| { // tail call: only the body and e stay live
                    e = bind(l, args); vs.items.len = b; const x = l.body;
                    const mk = if (ks.items.len > m.base) &ks.items[ks.items.len - 1].mark else &m.m0;
                    mk.* = gc.resweep(mk.*, x, e); continue :sw .{ .eval = x };
                },
                .f => |n| switch (n.f) {
                    .plain => |p| { const v = try p(n, args); vs.items.len = b; continue :sw .{ .ret = v }; },
                    .step => continue :sw try runtime.start(b, e), // a native frame: the arguments stay on vs
                },
                else => return fail(str("ToyLisp: {f} is not a function", .{f})),
            }
        },
    }
}
