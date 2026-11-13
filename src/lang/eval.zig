// The tree tier's evaluator: an explicit-stack machine that runs the nodes compile.zig builds. It is the reference
// semantics; a function whose body vm/compiler.zig can compile is handed to vm/exec.zig instead (the `.vm` step).
const std = @import("std");
const gc = @import("../runtime/gc.zig");
const rt = @import("../runtime/runtime.zig");
const scope = @import("../runtime/scope.zig");
const prims = @import("../runtime/primitives.zig");
const compile = @import("compile.zig");
const compiler = @import("../vm/compiler.zig");
const vm = @import("../vm/exec.zig");
const V = rt.V;
const Node = rt.Node;

/// The value if n is a constant or a variable, else null; compiles n on demand.
inline fn leaf(n: *Node, e: *rt.Env) rt.E!?V {
    if (n.stamp != compile.current()) try compile.force(n);
    return switch (n.code) {
        .val => |v| v,
        .ref => |*r| scope.fetch(e, r),
        else => null,
    };
}

/// A leaf, or a primitive call on leaves that computes in place (rt.Prim).
inline fn atom(n: *Node, e: *rt.Env) rt.E!?V {
    if (try leaf(n, e)) |v| return v;
    return if (n.code == .prim and !n.code.prim.slow) try inplace(n.code.prim, e, 3) else null;
}

/// The value of a primitive call whose operands are leaves or, a few levels deep (so native recursion stays bounded),
/// primitive calls themselves; null if it has to be an ordinary call. Kept out of line: inlined into `run` it slows everything.
fn inplace(p: *rt.Prim, e: *rt.Env, depth: u8) rt.E!?V {
    if (p.sym.local or p.g.* != p.f) return null; // the name was rebound
    var x = [2]V{ .nil, .nil };
    inline for (0..2) |i| if (i + 1 < p.c.len) {
        const n = p.c[i + 1];
        x[i] = try leaf(n, e) orelse
            if (n.code == .prim and depth > 0 and !n.code.prim.slow)
                (try inplace(n.code.prim, e, depth - 1) orelse return null)
            else {
                p.slow = true;
                return null;
            };
    };
    return if (p.c.len == 2) prims.fast1(p.op, x[0]) else prims.fast(p.op, x[0], x[1]);
}

// No native recursion per call, nesting level or callback: pending work is a frame on rt.ks, a call's values are collected
// on rt.vs, and each step is a rt.Go: evaluate a node, hand a value to the innermost frame, collect operands, or apply vs[b].

pub fn eval(ast: V, env: *rt.Env) rt.E!V {
    return exec(.{ .eval = compile.stub(ast) }, env);
}

/// Run from go until its first step has a value; an error goes to the innermost `try`.
pub fn exec(go: rt.Go, env: *rt.Env) rt.E!V {
    var m: rt.Machine = .{ .e = env, .base = rt.ks.items.len }; // ks[base..] are this run's frames
    const vbase = rt.vs.items.len;
    gc.push(*rt.Machine, &rt.machines, &m); // its scope is a collector root
    defer rt.machines.items.len -= 1;
    errdefer rt.ks.items.len, rt.vs.items.len = .{ m.base, vbase };
    var step = go;
    while (true) return run(&m, step) catch |err| {
        step = rt.recover(m.base) orelse return err;
        continue;
    };
}

fn run(m: *rt.Machine, go: rt.Go) rt.E!V {
    const ks = &rt.ks;
    const vs = &rt.vs;
    sw: switch (go) {
        .eval => |n| {
            if (!compile.in_macro and gc.due()) gc.collect(); // all live managed values are rooted
            if (try atom(n, m.e)) |v| continue :sw .{ .ret = v };
            switch (n.code) {
                .lambda => |p| continue :sw .{ .ret = scope.lambda(p, m.e) },
                .@"if" => |c| {
                    if (try atom(c[0], m.e)) |v| continue :sw .{ .eval = c[if (rt.truthy(v)) 1 else 2] };
                    _ = rt.frame(.@"if", c, m.e);
                    continue :sw .{ .eval = c[0] };
                },
                .begin => |c| {
                    if (c.len > 1) _ = rt.frame(.begin, c, m.e);
                    continue :sw .{ .eval = c[0] };
                },
                .prim => |p| continue :sw .{ .args = .{ .c = p.c, .i = 0, .b = vs.items.len } }, // not computable in place: the plain call
                .@"&&", .@"||" => |c| {
                    if (c.len > 1) _ = rt.frame(if (n.code == .@"&&") .@"&&" else .@"||", c, m.e);
                    continue :sw .{ .eval = c[0] };
                },
                .def => |d| {
                    if (try atom(d.val, m.e)) |v| {
                        try scope.assign(d, m.e, v);
                        continue :sw .{ .ret = v };
                    }
                    rt.frame(.def, &.{}, m.e).d = d;
                    continue :sw .{ .eval = d.val };
                },
                .call => |c| continue :sw .{ .args = .{ .c = c, .i = 0, .b = vs.items.len } },
                else => unreachable,
            }
        },
        .vm => |x| {
            if (!compile.in_macro and gc.due()) gc.collect();
            continue :sw try vm.exec(m, x.code, x.pc);
        },
        .ret => |v| {
            if (ks.items.len == m.base) return v;
            const k = &ks.items[ks.items.len - 1];
            const c = k.c;
            if (m.e != k.e) scope.release(m.e); // the call that returned is over
            m.e = k.e;
            switch (k.kind) {
                .@"if" => {
                    ks.items.len -= 1;
                    continue :sw .{ .eval = c[if (rt.truthy(v)) 1 else 2] };
                },
                .begin => {
                    k.i += 1;
                    if (k.i == c.len - 1) ks.items.len -= 1; // the last one is a tail position
                    continue :sw .{ .eval = c[k.i] };
                },
                .@"&&", .@"||" => if (rt.truthy(v) == (k.kind == .@"&&")) {
                    k.i += 1;
                    if (k.i == c.len - 1) ks.items.len -= 1;
                    continue :sw .{ .eval = c[k.i] };
                } else {
                    ks.items.len -= 1;
                    continue :sw .{ .ret = v };
                },
                .def => {
                    try scope.assign(k.d, m.e, v);
                    ks.items.len -= 1;
                    continue :sw .{ .ret = v };
                },
                .native => continue :sw try rt.step(k, v),
                .vm => {
                    const code = k.code;
                    const pc = k.i;
                    ks.items.len -= 1;
                    gc.push(V, vs, v);
                    continue :sw .{ .vm = .{ .code = code, .pc = pc } };
                },
                .loop => {
                    k.iter_env = null; // the iteration's scope was released above
                    gc.push(V, vs, v);
                    continue :sw .{ .vm = .{ .code = k.code, .pc = k.i } };
                },
                .call => {
                    ks.items.len -= 1;
                    try rt.operand(c, k.i, v);
                    continue :sw .{ .args = .{ .c = c, .i = k.i + 1, .b = k.base } };
                },
            }
        },
        .args => |a| { // push the function and arguments from a.i on; constants and variables need no frame
            var i = a.i;
            while (i < a.c.len) : (i += 1) {
                const v = try atom(a.c[i], m.e) orelse {
                    const k = rt.frame(.call, a.c, m.e);
                    k.i = i;
                    k.base = a.b;
                    continue :sw .{ .eval = a.c[i] };
                };
                try rt.operand(a.c, i, v);
            }
            continue :sw .{ .apply = a.b };
        },
        .apply => |b| {
            const f = vs.items[b];
            const args = vs.items[b + 1 ..];
            switch (f.tag()) {
                .lam => { // a tail call: only the new scope stays live
                    const l = f.asLam();
                    const code = compiler.ready(l.proto); // (compiling may expand macros, which runs the machine: take the arguments after it)
                    if (ks.items.len == m.base or ks.items[ks.items.len - 1].e != m.e) scope.release(m.e); // no frame needs the old one
                    m.e = scope.bind(l, vs.items[b + 1 ..]);
                    vs.items.len = b;
                    continue :sw if (code) |c| .{ .vm = .{ .code = c, .pc = 0 } } else .{ .eval = l.proto.body };
                },
                .f => {
                    const n = f.asFn();
                    switch (n.f) {
                        .plain => |p| {
                            const v = try p(n, args);
                            vs.items.len = b;
                            continue :sw .{ .ret = v };
                        },
                        .step => continue :sw try rt.start(b, m.e), // a native frame: the arguments stay on vs
                    }
                },
                else => return rt.fail(rt.str("TinyLisp: {f} is not a function", .{f})),
            }
        },
    }
}
