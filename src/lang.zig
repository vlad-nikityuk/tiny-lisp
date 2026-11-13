// The compiler and explicit-stack evaluator. Parsing lives in parser.zig.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const vm = @import("vm.zig");
const V = rt.V;
const Node = rt.Node;

pub var out: *std.Io.Writer = undefined;
pub var errv: V = .nil;
pub const parse = @import("parser.zig").parse;

// compiler
// ----------------------------------------------------------------
// The AST becomes nodes (rt.Node) once, lazily: a node is compiled when first evaluated, so macros see code in the order it
// runs. Every macro/* runs once per node; a new or redefined one (rt.epoch) recompiles all nodes. Nodes and symbols are
// permanent; their AST is pinned.

/// While a macro runs, code is not expanded (so expansion nests one level).
pub var in_macro = false;

// compiler support code is in runtime.zig
const make = rt.make;
pub const stub = rt.stub;
const kids = rt.kids;
const intern = rt.intern;

/// The stamp of up-to-date code; 0 means not compiled yet.
pub fn current() u32 {
    return rt.epoch *% 2 +% @intFromBool(in_macro) +% 1;
}

/// Every macro/* over x in turn; one that returns a false value leaves x as it was.
fn expand(x: V) rt.E!V {
    in_macro = true;
    defer in_macro = false;
    var y = x;
    for (rt.macros.items) |macro| {
        const b = rt.vs.items.len;
        defer rt.vs.items.len = b;
        gc.push(V, &rt.vs, macro.*);
        gc.push(V, &rt.vs, y);
        const z = try exec(.{ .apply = b }, rt.root);
        if (rt.truthy(z)) y = z;
    }
    return y;
}

/// The code of a list: a special form by its head, or a call.
fn form(a: []const V) rt.E!rt.Code {
    if (a.len == 0) return rt.fail(rt.str("TinyLisp: cannot evaluate an empty list", .{}));
    const head = if (a[0].is(.s)) std.meta.stringToEnum(rt.Form, std.mem.span(a[0].asStr())) orelse .apply else .apply;
    switch (head) {
        .quote => return .{ .val = rt.arg(a, 1) },
        .lambda => {
            const ps = rt.items(rt.arg(a, 1));
            const params = make(rt.Key, ps.len);
            const proto = &make(rt.Proto, 1)[0];
            proto.* = .{ .params = params[0..0], .body = stub(rt.arg(a, 2)) };
            var n: usize = 0;
            for (ps) |p| {
                if (p.is(.s) and std.mem.eql(u8, std.mem.span(p.asStr()), "&")) { // (a b & rest): rest takes the extra arguments
                    proto.rest = true;
                    continue;
                }
                const sym = intern(p);
                if (sym.prim and !sym.local) rt.epoch +%= 1;
                sym.local = true;
                params[n] = sym.key;
                n += 1;
                proto.params = params[0..n];
            }
            return .{ .lambda = proto };
        },
        .@"if" => return .{ .@"if" = kids(a[1..], 3) },
        .begin => return .{ .begin = kids(a[1..], @max(a.len - 1, 1)) }, // (begin) is nil
        .@"&&" => return .{ .@"&&" = kids(a[1..], @max(a.len - 1, 1)) }, // short-circuit
        .@"||" => return .{ .@"||" = kids(a[1..], @max(a.len - 1, 1)) },
        .define, .@"set!" => {
            const d = &make(rt.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = stub(rt.arg(a, 2)), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return rt.special(a, kids(a, a.len)),
    }
}

/// Expand macros over n's AST, then build its code unless they changed nothing.
pub fn force(n: *Node) rt.E!void {
    const x = if (in_macro or rt.ptr(n.ast) == null) n.ast else try expand(n.ast);
    if (n.code == .raw or x != n.src) {
        n.code = switch (x.tag()) {
            .s => .{ .ref = .{ .sym = intern(x) } },
            .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
            .l => try form(x.asList().items()),
            else => .{ .val = x },
        };
        if (n.code == .lambda) n.code.lambda.guard = n.guard;
        n.src = rt.pin(x);
    }
    n.stamp = current();
}

/// The value if n is a constant or a variable, else null; compiles n on demand.
inline fn leaf(n: *Node, e: *rt.Env) rt.E!?V {
    if (n.stamp != current()) try force(n);
    return switch (n.code) {
        .val => |v| v,
        .ref => |*r| rt.fetch(e, r),
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
    return if (p.c.len == 2) rt.fast1(p.op, x[0]) else rt.fast(p.op, x[0], x[1]);
}

// evaluator
// ----------------------------------------------------------------
// No native recursion per call, nesting level or callback: pending work is a frame on rt.ks, a call's values are collected
// on rt.vs, and each step is a rt.Go: evaluate a node, hand a value to the innermost frame, collect operands, or apply vs[b].

pub fn eval(ast: V, env: *rt.Env) rt.E!V {
    return exec(.{ .eval = stub(ast) }, env);
}

/// Run from go until its first step has a value; an error goes to the innermost `try`.
fn exec(go: rt.Go, env: *rt.Env) rt.E!V {
    var m: rt.M = .{ .e = env, .base = rt.ks.items.len }; // ks[base..] are this run's frames
    const vbase = rt.vs.items.len;
    gc.push(*rt.M, &rt.machines, &m); // its scope is a collector root
    defer rt.machines.items.len -= 1;
    errdefer rt.ks.items.len, rt.vs.items.len = .{ m.base, vbase };
    var step = go;
    while (true) return run(&m, step) catch |err| {
        step = rt.recover(m.base) orelse return err;
        continue;
    };
}

fn run(m: *rt.M, go: rt.Go) rt.E!V {
    const ks = &rt.ks;
    const vs = &rt.vs;
    sw: switch (go) {
        .eval => |n| {
            if (!in_macro and gc.due()) gc.collect(); // all live managed values are rooted
            if (try atom(n, m.e)) |v| continue :sw .{ .ret = v };
            switch (n.code) {
                .lambda => |p| continue :sw .{ .ret = rt.lambda(p, m.e) },
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
                        try rt.assign(d, m.e, v);
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
            if (!in_macro and gc.due()) gc.collect();
            continue :sw try vm.exec(m, x.code, x.pc);
        },
        .ret => |v| {
            if (ks.items.len == m.base) return v;
            const k = &ks.items[ks.items.len - 1];
            const c = k.c;
            if (m.e != k.e) rt.release(m.e); // the call that returned is over
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
                    try rt.assign(k.d, m.e, v);
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
                    k.env2 = null; // the iteration's scope was released above
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
                    const code = vm.ready(l.proto); // (compiling may expand macros, which runs the machine: take the arguments after it)
                    if (ks.items.len == m.base or ks.items[ks.items.len - 1].e != m.e) rt.release(m.e); // no frame needs the old one
                    m.e = rt.bind(l, vs.items[b + 1 ..]);
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
