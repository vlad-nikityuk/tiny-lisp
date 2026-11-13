// Tier 2: the body of a function is compiled, on its first call, to a stack bytecode, and the function's
// parameters and defines get fixed slots in its scope (rt.bind creates them all up front). The bytecode runs inside the machine of
// lang.zig: `exec` returns the next rt.Go (a call, or a return) and a call that is not a tail call leaves a `vm` frame on rt.ks
// that resumes the code at the instruction after it. Anything this compiler does not know (a body nested too deep, a define that may not run, an
// error while expanding macros) leaves the function to the tree evaluator, which stays the reference semantics.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const lang = @import("lang.zig");
const V = rt.V;
const Node = rt.Node;
const E = rt.E;

const Op = rt.Opcode;
const max_depth = 120; // source nesting the compiler follows (it recurses)

const Comp = struct {
    ins: std.ArrayList(rt.Ins) = .empty,
    consts: std.ArrayList(V) = .empty,
    refs: std.ArrayList(*rt.Ref) = .empty,
    prims: std.ArrayList(*rt.Prim) = .empty,
    defs: std.ArrayList(*rt.Def) = .empty,
    protos: std.ArrayList(*rt.Proto) = .empty,
    keys: std.ArrayList(rt.Key) = .empty,
    seen: std.ArrayList(rt.Key) = .empty, // names read or set! so far, in scan order
    cond: usize = 0, // > 0 while scanning code that may not run

    fn emit(c: *Comp, op: Op, a: usize, b: usize) usize {
        c.ins.append(std.heap.c_allocator, .{ .op = op, .a = @intCast(a), .b = @intCast(b) }) catch gc.oom();
        return c.ins.items.len - 1;
    }

    fn add(c: *Comp, comptime T: type, list: *std.ArrayList(T), x: T) usize {
        _ = c;
        list.append(std.heap.c_allocator, x) catch gc.oom();
        return list.items.len - 1;
    }

    fn slotOf(c: *Comp, sym: *rt.Sym) ?usize {
        for (c.keys.items, 0..) |k, i| if (k == sym.key) return i;
        return null;
    }

    fn forced(n: *Node) E!void {
        if (n.stamp != lang.current()) try lang.force(n);
    }

    fn seenBefore(c: *Comp, sym: *rt.Sym) bool {
        for (c.seen.items) |k| if (k == sym.key) return true;
        return false;
    }

    /// Find the defines of the body (they get slots) and reject what this tier does not do. A name a define adds is bound from the
    /// start of the call, so a define that may not run, or comes after a use of the same name (which would then mean an outer
    /// binding), is left to the tree evaluator, where the name is only bound once the define has run.
    fn scan(c: *Comp, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val, .lambda => {}, // a lambda's body is compiled when it is called
            .ref => |r| if (!c.seenBefore(r.sym)) {
                _ = c.add(rt.Key, &c.seen, r.sym.key);
            },
            .@"if" => |k| {
                try c.scan(k[0], depth + 1);
                c.cond += 1;
                defer c.cond -= 1;
                try c.scan(k[1], depth + 1);
                try c.scan(k[2], depth + 1);
            },
            .@"&&", .@"||" => |k| for (k, 0..) |x, i| {
                if (i > 0) c.cond += 1;
                try c.scan(x, depth + 1);
            },
            .begin, .call => |kids| for (kids) |k| try c.scan(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try c.scan(k, depth + 1),
            .def => |d| {
                try c.scan(d.val, depth + 1);
                const sym = d.sym orelse return error.Bail;
                if (!d.define) {
                    if (!c.seenBefore(sym)) _ = c.add(rt.Key, &c.seen, sym.key);
                } else {
                    if (c.cond > 0 or c.seenBefore(sym)) return error.Bail;
                    if (c.slotOf(sym) == null) _ = c.add(rt.Key, &c.keys, sym.key);
                    sym.local = true;
                }
            },
            else => return error.Bail,
        }
    }

    fn patch(c: *Comp, at: usize) void {
        c.ins.items[at].b = @intCast(c.ins.items.len);
    }

    /// Code that leaves the value of n on the stack; in tail position it returns it (or tail-calls) instead.
    fn gen(c: *Comp, n: *Node, tail: bool) !void {
        switch (n.code) {
            .val => |v| {
                _ = c.emit(.konst, c.add(V, &c.consts, v), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .ref => |*r| {
                if (c.slotOf(r.sym)) |i| _ = c.emit(.local, i, 0) else _ = c.emit(.outer, c.add(*rt.Ref, &c.refs, r), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .@"if" => |k| {
                try c.genAll(k[0], false);
                const jf = c.emit(.jmpf, 0, 0);
                try c.genAll(k[1], tail);
                const j = if (tail) 0 else c.emit(.jmp, 0, 0);
                c.patch(jf);
                try c.genAll(k[2], tail);
                if (!tail) c.patch(j);
            },
            .begin => |k| {
                for (k[0 .. k.len - 1]) |s| {
                    try c.genAll(s, false);
                    _ = c.emit(.pop, 0, 0);
                }
                try c.genAll(k[k.len - 1], tail);
            },
            .@"&&", .@"||" => |k| {
                var jumps: [64]usize = undefined;
                if (k.len > jumps.len) return error.Bail;
                for (k[0 .. k.len - 1], 0..) |x, i| {
                    try c.genAll(x, false);
                    jumps[i] = c.emit(if (n.code == .@"&&") .andj else .orj, 0, 0);
                }
                try c.genAll(k[k.len - 1], false);
                for (jumps[0 .. k.len - 1]) |at| c.patch(at);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .prim => |p| {
                if (p.sym.local or p.g.* != p.f) return c.gen_call(p.c, tail); // rebound since it was compiled: an ordinary call
                for (p.c[1..]) |x| try c.genAll(x, false);
                const op: Op = switch (p.op) {
                    .@"+" => .add,
                    .@"-" => .sub,
                    .@"*" => .mul,
                    .@"<" => .lt,
                    .@">" => .gt,
                    .@"<=" => .le,
                    .@">=" => .ge,
                    .@"eq?" => .eq,
                    .at => .at,
                    else => if (p.c.len == 2) .prim1 else .prim2,
                };
                _ = c.emit(op, c.add(*rt.Prim, &c.prims, p), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .call => |k| try c.gen_call(k, tail),
            .lambda => |lp| {
                _ = c.emit(.lambda, c.add(*rt.Proto, &c.protos, lp), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .def => |d| {
                try c.genAll(d.val, false);
                if (d.sym) |sym| if (c.slotOf(sym)) |i| {
                    _ = c.emit(.setlocal, i, 0);
                    if (tail) _ = c.emit(.ret, 0, 0);
                    return;
                };
                _ = c.emit(.setouter, c.add(*rt.Def, &c.defs, d), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            else => return error.Bail,
        }
    }

    fn gen_call(c: *Comp, k: []const *Node, tail: bool) !void {
        for (k) |x| try c.genAll(x, false);
        _ = c.emit(if (tail) .tailcall else .call, k.len - 1, c.add(V, &c.consts, k[0].ast));
    }

    fn genAll(c: *Comp, n: *Node, tail: bool) error{Bail}!void {
        c.gen(n, tail) catch return error.Bail;
    }
};

fn compile(p: *rt.Proto) void {
    p.tried = true;
    var c: Comp = .{};
    defer inline for (.{ &c.ins, &c.consts, &c.refs, &c.prims, &c.defs, &c.protos, &c.keys, &c.seen }) |l| l.deinit(std.heap.c_allocator);
    for (p.params) |k| _ = c.add(rt.Key, &c.keys, k);
    c.scan(p.body, 0) catch return;
    c.gen(p.body, true) catch return;
    const code = &rt.make(rt.Bytecode, 1)[0];
    code.* = .{ .ins = @constCast(dup(rt.Ins, c.ins.items)), .consts = dup(V, c.consts.items), .refs = dup(*rt.Ref, c.refs.items), .prims = dup(*rt.Prim, c.prims.items), .defs = dup(*rt.Def, c.defs.items), .protos = dup(*rt.Proto, c.protos.items), .keys = dup(rt.Key, c.keys.items), .stamp = lang.current() };
    for (code.consts) |v| _ = rt.pin(v);
    p.code = code;
}

fn dup(comptime T: type, xs: []const T) []const T {
    const m = rt.make(T, xs.len);
    @memcpy(m, xs);
    return m;
}

/// The bytecode of p, compiled on first use and again after a macro changed; null if p stays with the tree evaluator.
pub fn ready(p: *rt.Proto) ?*rt.Bytecode {
    if (lang.in_macro) return null;
    if (p.code) |c| {
        if (c.stamp == lang.current()) return c;
        p.code = null;
        p.tried = false;
    }
    if (!p.tried) compile(p);
    return p.code;
}

inline fn arith(comptime op: Op, vs: *std.ArrayList(V)) bool {
    const n = vs.items.len;
    const x = vs.items[n - 2];
    const y = vs.items[n - 1];
    if (op == .eq) {
        vs.items.len = n - 1;
        vs.items[n - 2] = V.boolean(rt.eq(x, y));
        return true;
    }
    if (op == .at) {
        if (!x.is(.l) or !y.isNum()) return false;
        const l = x.asList().items();
        const i = y.asNum();
        if (!(i >= 0 and i < @as(f64, @floatFromInt(l.len)))) return false;
        vs.items.len = n - 1;
        vs.items[n - 2] = l[@intFromFloat(i)];
        return true;
    }
    if (!x.isNum() or !y.isNum()) return false;
    const p = x.asNum();
    const q = y.asNum();
    vs.items.len = n - 1;
    vs.items[n - 2] = switch (op) {
        .add => V.num(p + q),
        .sub => V.num(p - q),
        .mul => V.num(p * q),
        .lt => V.boolean(p < q),
        .gt => V.boolean(p > q),
        .le => V.boolean(p <= q),
        else => V.boolean(p >= q),
    };
    return true;
}

/// The slot of a name that is not one of this function's slots. The first lookup of an instruction notes where the name was found
/// ((hops + 1) << 16 | index in b); the scopes it passed must have a fixed layout (tier 2), so later lookups go straight there
/// and only check the key.
inline fn outerSlot(e: *rt.Env, ins: *rt.Ins, sym: *rt.Sym, g: *?*V) ?*V {
    if (ins.b != 0) {
        var s = e;
        var hops = ins.b >> 16;
        while (hops > 0) : (hops -= 1) s = s.p.?;
        const i = ins.b & 0xffff;
        if (i < s.vars.len and s.vars[i].k == sym.key) return &s.vars[i].v;
    }
    return outerLook(e, ins, sym, g);
}

noinline fn outerLook(e: *rt.Env, ins: *rt.Ins, sym: *rt.Sym, g: *?*V) ?*V {
    var s = e;
    var hops: u32 = 0;
    var fixed = true; // every scope passed so far is a tier-2 scope
    while (sym.local and s.p != null) : (s = s.p.?) {
        var i = s.vars.len;
        while (i > 0) : (i -= 1) if (s.vars[i - 1].k == sym.key) {
            if (fixed and hops < 0x7fff and i - 1 < 0x10000) ins.b = (hops << 16) | @as(u32, @intCast(i - 1));
            return &s.vars[i - 1].v;
        };
        fixed = fixed and s.proto != null and s.proto.?.code != null;
        hops += 1;
    }
    if (g.* == null) g.* = rt.slotOf(rt.root, sym.key);
    return g.*;
}

/// An operation on values it does not compute in place: call whatever its name is now (it was a primitive when compiled).
fn slow(m: *rt.M, code: *rt.Bytecode, ip: [*]const rt.Ins, arity: usize) E!rt.Go {
    const p = code.prims[ip[0].a];
    const vs = &rt.vs;
    const n = vs.items.len;
    var g: ?*V = null;
    const f = if (rt.find(m.e, p.sym, &g)) |s| s.* else V.nil;
    if (f == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{p.c[0].ast}));
    vs.insert(rt.gpa, n - arity, f) catch gc.oom();
    return call(m, n - arity, code, (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(rt.Ins) + 1);
}

/// Run code from pc until it calls or returns; the next step is the result.
pub noinline fn exec(m: *rt.M, code: *rt.Bytecode, pc0: usize) E!rt.Go {
    const vs = &rt.vs;
    const e = m.e;
    var ip = code.ins.ptr + pc0;
    sw: switch (ip[0].op) {
        .konst => {
            gc.push(V, vs, code.consts[ip[0].a]);
            ip += 1;
            continue :sw ip[0].op;
        },
        .local => {
            gc.push(V, vs, e.vars[ip[0].a].v);
            ip += 1;
            continue :sw ip[0].op;
        },
        .outer => {
            const r = code.refs[ip[0].a];
            gc.push(V, vs, if (outerSlot(e, &ip[0], r.sym, &r.g)) |p| p.* else V.nil);
            ip += 1;
            continue :sw ip[0].op;
        },
        .setlocal => {
            e.vars[ip[0].a].v = vs.items[vs.items.len - 1];
            ip += 1;
            continue :sw ip[0].op;
        },
        .setouter => {
            const d = code.defs[ip[0].a];
            if (d.define) try rt.assign(d, e, vs.items[vs.items.len - 1]) else if (outerSlot(e, &ip[0], d.sym.?, &d.g)) |p| {
                if (p.*.is(.f)) rt.epoch +%= 1; // as rt.assign does
                p.* = vs.items[vs.items.len - 1];
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .lambda => {
            gc.push(V, vs, rt.lambda(code.protos[ip[0].a], e));
            ip += 1;
            continue :sw ip[0].op;
        },
        .pop => {
            vs.items.len -= 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .jmp => {
            ip = code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .jmpf => {
            const v = vs.items[vs.items.len - 1];
            vs.items.len -= 1;
            ip = if (rt.truthy(v)) ip + 1 else code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .andj, .orj => { // decided (false for &&, true for ||): keep the value and jump; else drop it and go on
            const v = vs.items[vs.items.len - 1];
            if (rt.truthy(v) == (ip[0].op == .orj)) ip = code.ins.ptr + ip[0].b else {
                vs.items.len -= 1;
                ip += 1;
            }
            continue :sw ip[0].op;
        },
        inline .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .at => |op| {
            if (!arith(op, vs)) return slow(m, code, ip, 2);
            ip += 1;
            continue :sw ip[0].op;
        },
        .prim1, .prim2 => {
            const p = code.prims[ip[0].a];
            const n = vs.items.len;
            const unary = ip[0].op == .prim1;
            const r = if (unary) rt.fast1(p.op, vs.items[n - 1]) else rt.fast(p.op, vs.items[n - 2], vs.items[n - 1]);
            const v = r orelse return slow(m, code, ip, if (unary) 1 else 2);
            vs.items.len = if (unary) n else n - 1;
            vs.items[vs.items.len - 1] = v;
            ip += 1;
            continue :sw ip[0].op;
        },
        .call => {
            const b = vs.items.len - ip[0].a - 1;
            if (vs.items[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return call(m, b, code, (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(rt.Ins) + 1);
        },
        .tailcall => {
            const b = vs.items.len - ip[0].a - 1;
            if (vs.items[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return .{ .apply = b };
        },
        .ret => {
            const v = vs.items[vs.items.len - 1];
            vs.items.len -= 1;
            return .{ .ret = v };
        },
    }
}

/// A call that is not a tail call: leave a frame that resumes at pc with the value pushed.
fn call(m: *rt.M, b: usize, code: *rt.Bytecode, pc: usize) rt.Go {
    const k = rt.frame(.vm, &.{}, m.e);
    k.i = pc;
    k.base = b;
    k.code = code;
    return .{ .apply = b };
}
