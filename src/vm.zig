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
    bodies: std.ArrayList(?*rt.Bytecode) = .empty, // by the same index: the compiled body of a loop lambda
    keys: std.ArrayList(rt.Key) = .empty,
    seen: std.ArrayList(rt.Key) = .empty, // names read or set! so far, in scan order
    cond: usize = 0, // > 0 while scanning code that may not run (the depth of such regions)
    held: std.ArrayList(struct { key: rt.Key, level: usize }) = .empty, // names defined in the regions being scanned
    closed: std.ArrayList(rt.Key) = .empty, // names defined in a region that is over: a later use would not be sure of the define
    self: ?*rt.Proto = null,
    inl: ?struct { keys: []const rt.Key, base: usize } = null, // while an inlined function's body is generated: its names and where its slots start
    sites: usize = 0, // functions inlined so far
    barrier: usize = 0, // the last jump target: instructions before it are not merged with the ones after

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
        const keys = if (c.inl) |i| i.keys else c.keys.items;
        const base = if (c.inl) |i| i.base else 0;
        var i = keys.len; // the last of equal names wins, as in a scope search
        while (i > 0) : (i -= 1) if (keys[i - 1] == sym.key) return base + i - 1;
        return null;
    }

    fn forced(n: *Node) E!void {
        if (n.stamp != lang.current()) try lang.force(n);
    }

    /// The names a nested lambda reads or sets count as used where the lambda is made (it may run before a later define of the same name).
    fn scanUses(c: *Comp, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val => {},
            .ref => |r| {
                if (c.isClosed(r.sym)) return error.Bail;
                if (c.slotOf(r.sym) == null and !c.seenBefore(r.sym)) _ = c.add(rt.Key, &c.seen, r.sym.key);
            },
            .@"if", .begin, .@"&&", .@"||", .call => |kids| for (kids) |k| try c.scanUses(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try c.scanUses(k, depth + 1),
            .def => |d| {
                try c.scanUses(d.val, depth + 1);
                if (!d.define) if (d.sym) |sym| {
                    if (c.isClosed(sym)) return error.Bail;
                    if (c.slotOf(sym) == null and !c.seenBefore(sym)) _ = c.add(rt.Key, &c.seen, sym.key);
                };
            },
            .lambda => |lp| try c.scanUses(lp.body, depth + 1),
            else => return error.Bail,
        }
    }

    fn enter(c: *Comp) void {
        c.cond += 1;
    }

    /// End of a region that may not run: the names it defined can no longer be used (they are bound from the start of the call,
    /// but only defined if the region ran).
    fn leave(c: *Comp) void {
        c.cond -= 1;
        while (c.held.items.len > 0 and c.held.items[c.held.items.len - 1].level > c.cond) {
            _ = c.add(rt.Key, &c.closed, c.held.items[c.held.items.len - 1].key);
            c.held.items.len -= 1;
        }
    }

    fn isClosed(c: *Comp, sym: *rt.Sym) bool {
        for (c.closed.items) |k| if (k == sym.key) return true;
        return false;
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
            .val => {},
            .lambda => |lp| try c.scanUses(lp.body, depth + 1),
            .ref => |r| {
                if (c.isClosed(r.sym)) return error.Bail;
                if (c.slotOf(r.sym) == null and !c.seenBefore(r.sym)) _ = c.add(rt.Key, &c.seen, r.sym.key);
            },
            .@"if" => |k| {
                try c.scan(k[0], depth + 1);
                c.enter();
                try c.scan(k[1], depth + 1);
                c.leave();
                c.enter();
                try c.scan(k[2], depth + 1);
                c.leave();
            },
            .@"&&", .@"||" => |k| for (k, 0..) |x, i| {
                if (i > 0) c.enter();
                try c.scan(x, depth + 1);
                if (i > 0) c.leave();
            },
            .begin, .call => |kids| for (kids) |k| try c.scan(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try c.scan(k, depth + 1),
            .def => |d| {
                try c.scan(d.val, depth + 1);
                const sym = d.sym orelse return error.Bail;
                if (c.isClosed(sym)) return error.Bail;
                if (!d.define) {
                    if (c.slotOf(sym) == null and !c.seenBefore(sym)) _ = c.add(rt.Key, &c.seen, sym.key);
                } else {
                    if (c.seenBefore(sym)) return error.Bail;
                    if (c.slotOf(sym) == null) _ = c.add(rt.Key, &c.keys, sym.key);
                    if (c.cond > 0) _ = c.add(@TypeOf(c.held.items[0]), &c.held, .{ .key = sym.key, .level = c.cond });
                    sym.local = true;
                }
            },
            else => return error.Bail,
        }
    }

    fn patch(c: *Comp, at: usize) void {
        c.barrier = c.ins.items.len;
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
                if (c.slotOf(r.sym)) |i| _ = c.emit(.local, i, 0) else _ = c.emit(if (c.inl != null) .global else .outer, c.add(*rt.Ref, &c.refs, r), 0);
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
                    .mod => .mod,
                    .@"/" => .div,
                    .not => .not,
                    else => if (p.c.len == 2) .prim1 else .prim2,
                };
                const pi = c.add(*rt.Prim, &c.prims, p);
                if (!c.fuse(op, pi)) _ = c.emit(op, pi, 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .call => |k| try c.gen_call(k, tail),
            .lambda => |lp| {
                const at = c.add(*rt.Proto, &c.protos, lp);
                _ = c.add(?*rt.Bytecode, &c.bodies, null);
                _ = c.emit(.lambda, at, 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            .def => |d| {
                try c.genAll(d.val, false);
                if (d.sym) |sym| if (c.slotOf(sym)) |i| {
                    _ = c.emit(.setlocal, i, 0);
                    if (tail) _ = c.emit(.ret, 0, 0);
                    return;
                };
                _ = c.emit(if (c.inl != null) .setglobal else .setouter, c.add(*rt.Def, &c.defs, d), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
            },
            else => return error.Bail,
        }
    }

    /// (op local local) and (op local constant), the two operands just pushed, become one instruction (b: first slot << 16 | second).
    fn fuse(c: *Comp, op: Op, pi: usize) bool {
        const n = c.ins.items.len;
        if (n < 2 or n - 2 < c.barrier) return false;
        const x = c.ins.items[n - 2];
        const y = c.ins.items[n - 1];
        if (x.op != .local or (y.op != .local and y.op != .konst)) return false;
        const local = y.op == .local;
        const fused: Op = inline for (.{ .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .at }) |o| {
            if (op == o) break if (local) @field(Op, @tagName(o) ++ "_ll") else @field(Op, @tagName(o) ++ "_lk");
        } else return false;
        c.ins.items.len = n - 2;
        _ = c.emit(fused, pi, (@as(usize, x.a) << 16) | y.a);
        return true;
    }

    /// Is this body something to inline: small, no closures?
    fn inlinable(n: *Node, depth: usize, count: *usize) bool {
        count.* += 1;
        if (depth > 24 or count.* > 48) return false;
        return switch (n.code) {
            .val, .ref => true,
            .call => |kids| calls: {
                if (kids[0].code == .ref and !kids[0].code.ref.sym.local) if (rt.slotOf(rt.root, kids[0].code.ref.sym.key)) |g| {
                    if (g.*.is(.f) and g.*.asFn().f == .step) break :calls false; // a native that runs code in the scope it is called from (load, try, map...)
                };
                for (kids) |x| if (!inlinable(x, depth + 1, count)) break :calls false;
                break :calls true;
            },
            .@"if", .begin, .@"&&", .@"||" => |kids| for (kids) |x| {
                if (!inlinable(x, depth + 1, count)) break false;
            } else true,
            .prim => |p| for (p.c[1..]) |x| {
                if (!inlinable(x, depth + 1, count)) break false;
            } else true,
            .def => |d| inlinable(d.val, depth + 1, count),
            else => false,
        };
    }

    /// (f args...) where f is a small global function without closures: its body is generated here, with slots of its own for its
    /// parameters and defines and its free names read as globals. Redefining f compiles this code again (epoch).
    fn genInline(c: *Comp, k: []const *Node, tail: bool) !bool {
        if (c.inl != null or c.sites >= 8 or k[0].code != .ref) return false;
        const sym = k[0].code.ref.sym;
        const g = if (sym.local) null else rt.slotOf(rt.root, sym.key);
        const f = (g orelse return false).*;
        if (!f.is(.lam)) return false;
        const l = f.asLam();
        if (l.env != rt.root or l.proto == c.self or l.proto.rest or l.proto.params.len != k.len - 1) return false;
        var sub: Comp = .{};
        defer inline for (.{ &sub.ins, &sub.consts, &sub.refs, &sub.prims, &sub.defs, &sub.protos, &sub.bodies, &sub.keys, &sub.seen, &sub.held, &sub.closed }) |list| list.deinit(std.heap.c_allocator);
        for (l.proto.params) |pk| _ = sub.add(rt.Key, &sub.keys, pk);
        sub.scan(l.proto.body, 0) catch return false;
        var count: usize = 0;
        if (!inlinable(l.proto.body, 0, &count) or sub.keys.items.len > 8) return false;
        for (k[1..]) |x| try c.genAll(x, false);
        const base = c.keys.items.len;
        for (sub.keys.items) |_| _ = c.add(rt.Key, &c.keys, rt.mkstr("(inlined)", true)); // slots no name finds
        var i = k.len - 1;
        while (i > 0) : (i -= 1) _ = c.emit(.storelocal, base + i - 1, 0);
        l.proto.inlined = true;
        c.inl = .{ .keys = sub.keys.items, .base = base };
        c.sites += 1;
        defer c.inl = null;
        try c.genAll(l.proto.body, tail); // at a tail call site the body's own tail calls stay tail calls
        return true;
    }

    fn gen_call(c: *Comp, k: []const *Node, tail: bool) !void {
        if (try c.genInline(k, tail)) return;
        if (k.len == 3 and k[0].code == .ref and k[2].code == .lambda and k[2].guard != null) loop: { // (each list (lambda (x) ...)) as a loop of the bytecode
            const sym = k[0].code.ref.sym;
            const lp = k[2].code.lambda;
            const g = if (sym.local) null else rt.slotOf(rt.root, sym.key);
            const is_each = g != null and g.?.* == rt.each_v;
            const is_map = g != null and g.?.* == rt.map_v;
            if (!(is_each or is_map) or lp.params.len != 1 or lp.rest) break :loop;
            const body = ready(lp) orelse break :loop;
            sym.prim = true; // rebinding each or map makes epoch change, so this code is compiled again
            try c.genAll(k[1], false);
            const at = c.add(*rt.Proto, &c.protos, lp);
            _ = c.add(?*rt.Bytecode, &c.bodies, body);
            _ = c.emit(if (is_map) .map else .each, at, 0);
            _ = c.emit(if (is_map) .mapnext else .eachnext, at, 0);
            if (tail) _ = c.emit(.ret, 0, 0);
            return;
        }
        if (k.len == 4 and k[0].code == .ref) { // (vset! list index value), while vset! is the native
            const sym = k[0].code.ref.sym;
            const g = if (sym.local) null else rt.slotOf(rt.root, sym.key);
            if (g) |slotp| if (rt.isVset(slotp.*)) {
                for (k[1..]) |x| try c.genAll(x, false);
                sym.prim = true; // rebinding it makes epoch change, so this code is compiled again
                _ = c.emit(.vset, c.add(V, &c.consts, slotp.*), 0);
                if (tail) _ = c.emit(.ret, 0, 0);
                return;
            };
        }
        for (k) |x| try c.genAll(x, false);
        _ = c.emit(if (tail) .tailcall else .call, k.len - 1, c.add(V, &c.consts, k[0].ast));
    }

    fn genAll(c: *Comp, n: *Node, tail: bool) error{Bail}!void {
        c.gen(n, tail) catch return error.Bail;
    }
};

fn compile(p: *rt.Proto) void {
    p.tried = true;
    var c: Comp = .{ .self = p };
    defer inline for (.{ &c.ins, &c.consts, &c.refs, &c.prims, &c.defs, &c.protos, &c.bodies, &c.keys, &c.seen, &c.held, &c.closed }) |l| l.deinit(std.heap.c_allocator);
    for (p.params) |k| _ = c.add(rt.Key, &c.keys, k);
    c.scan(p.body, 0) catch return;
    c.gen(p.body, true) catch return;
    const code = &rt.make(rt.Bytecode, 1)[0];
    code.* = .{ .ins = @constCast(dup(rt.Ins, c.ins.items)), .consts = dup(V, c.consts.items), .refs = dup(*rt.Ref, c.refs.items), .prims = dup(*rt.Prim, c.prims.items), .defs = dup(*rt.Def, c.defs.items), .protos = dup(*rt.Proto, c.protos.items), .bodies = dup(?*rt.Bytecode, c.bodies.items), .keys = dup(rt.Key, c.keys.items), .stamp = lang.current(), .room = room(c.ins.items) }; // every instruction pushes at most one value, the start of a loop 2 or 3
    for (code.consts) |v| _ = rt.pin(v);
    p.code = code;
}

fn room(ins: []const rt.Ins) usize {
    var n: usize = 2;
    for (ins) |i| n += switch (i.op) {
        .map => 4,
        .each => 3,
        else => 1,
    };
    return n;
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

fn arith2(comptime op: Op, x: V, y: V) ?V {
    if (op == .eq) return V.boolean(if (x.isNum() and y.isNum()) x.asNum() == y.asNum() else rt.eq(x, y));
    if (op == .at) {
        if (!x.is(.l) or !y.isNum()) return null;
        const l = x.asList().items();
        const i = y.asNum();
        return if (i >= 0 and i < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(i)] else null;
    }
    if (!x.isNum() or !y.isNum()) return null;
    const p = x.asNum();
    const q = y.asNum();
    return switch (op) {
        .add => V.num(p + q),
        .sub => V.num(p - q),
        .mul => V.num(p * q),
        .mod => V.num(p - q * @floor(p / q)),
        .div => V.num(p / q),
        .lt => V.boolean(p < q),
        .gt => V.boolean(p > q),
        .le => V.boolean(p <= q),
        else => V.boolean(p >= q),
    };
}

inline fn arith(comptime op: Op, st: [*]V, sp: *usize) bool {
    const n = sp.*;
    const x = st[n - 2];
    const y = st[n - 1];
    if (op == .eq) {
        sp.* = n - 1;
        st[n - 2] = V.boolean(if (x.isNum() and y.isNum()) x.asNum() == y.asNum() else rt.eq(x, y));
        return true;
    }
    if (op == .at) {
        if (!x.is(.l) or !y.isNum()) return false;
        const l = x.asList().items();
        const i = y.asNum();
        if (!(i >= 0 and i < @as(f64, @floatFromInt(l.len)))) return false;
        sp.* = n - 1;
        st[n - 2] = l[@intFromFloat(i)];
        return true;
    }
    if (!x.isNum() or !y.isNum()) return false;
    const p = x.asNum();
    const q = y.asNum();
    sp.* = n - 1;
    st[n - 2] = switch (op) {
        .add => V.num(p + q),
        .sub => V.num(p - q),
        .mul => V.num(p * q),
        .mod => V.num(p - q * @floor(p / q)),
        .div => V.num(p / q),
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
    if (ins.b != 0 and ins.c == rt.shape) {
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
            if (fixed and hops < 0x7fff and i - 1 < 0x10000) {
                ins.b = (hops << 16) | @as(u32, @intCast(i - 1));
                ins.c = rt.shape;
            }
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

/// Run code from pc until it calls or returns; the next step is the result. The stack of values is rt.vs, with room for the whole
/// function reserved up front, so its top is kept in a local (sp) and rt.vs.items.len is brought up to date only when leaving.
pub noinline fn exec(m: *rt.M, code0: *rt.Bytecode, pc0: usize) E!rt.Go {
    const vs = &rt.vs;
    const ks = &rt.ks;
    var e = m.e;
    var code = code0;
    var ip = code.ins.ptr + pc0;
    if (vs.capacity - vs.items.len < code.room) vs.ensureTotalCapacity(rt.gpa, vs.items.len + code.room) catch gc.oom();
    var st = vs.items.ptr;
    var sp = vs.items.len;
    var depth: usize = 0; // loop bodies being run by this call of exec (each has a loop frame under the frames of its calls)
    sw: switch (ip[0].op) {
        .konst => {
            st[sp] = code.consts[ip[0].a];
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .local => {
            st[sp] = e.vars[ip[0].a].v;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .outer => {
            const r = code.refs[ip[0].a];
            st[sp] = if (outerSlot(e, &ip[0], r.sym, &r.g)) |p| p.* else V.nil;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .lambda => {
            st[sp] = rt.lambda(code.protos[ip[0].a], e);
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .setlocal => {
            e.vars[ip[0].a].v = st[sp - 1];
            ip += 1;
            continue :sw ip[0].op;
        },
        .setouter => {
            const d = code.defs[ip[0].a];
            if (d.define) try rt.assign(d, e, st[sp - 1]) else if (outerSlot(e, &ip[0], d.sym.?, &d.g)) |p| {
                if (rt.compiledInto(p.*)) rt.epoch +%= 1; // as rt.assign does
                p.* = st[sp - 1];
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .pop => {
            sp -= 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .jmp => {
            ip = code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .jmpf => {
            sp -= 1;
            ip = if (rt.truthy(st[sp])) ip + 1 else code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .andj, .orj => { // decided (false for &&, true for ||): keep the value and jump; else drop it and go on
            if (rt.truthy(st[sp - 1]) == (ip[0].op == .orj)) ip = code.ins.ptr + ip[0].b else {
                sp -= 1;
                ip += 1;
            }
            continue :sw ip[0].op;
        },
        .not => {
            st[sp - 1] = V.boolean(!rt.truthy(st[sp - 1]));
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .add, .sub, .mul, .mod, .div, .lt, .gt, .le, .ge, .eq, .at => |op| {
            if (!arith(op, st, &sp)) {
                vs.items.len = sp;
                return slow(m, code, ip, 2);
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .vset => { // (vset! list index value): the native itself does anything that is not an in-range store
            const l = st[sp - 3];
            const i = st[sp - 2];
            if (l.is(.l) and i.isNum()) {
                const items = l.asList().items();
                const x = i.asNum();
                if (x >= 0 and x < @as(f64, @floatFromInt(items.len))) {
                    items[@intFromFloat(x)] = st[sp - 1];
                    sp -= 2;
                    st[sp - 1] = items[@intFromFloat(x)];
                    ip += 1;
                    continue :sw ip[0].op;
                }
            }
            const n = code.consts[ip[0].a].asFn();
            vs.items.len = sp;
            const r = try n.f.plain(n, st[sp - 3 .. sp]);
            sp -= 2;
            st[sp - 1] = r;
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .add_lk, .sub_lk, .mul_lk, .lt_lk, .gt_lk, .le_lk, .ge_lk, .eq_lk, .at_lk, .add_ll, .sub_ll, .mul_ll, .lt_ll, .gt_ll, .le_ll, .ge_ll, .eq_ll, .at_ll => |op| {
            const name = comptime @tagName(op);
            const x = e.vars[ip[0].b >> 16].v;
            const y = if (comptime name[name.len - 1] == 'k') code.consts[ip[0].b & 0xffff] else e.vars[ip[0].b & 0xffff].v;
            if (arith2(@field(Op, name[0 .. name.len - 3]), x, y)) |v| {
                st[sp] = v;
                sp += 1;
                ip += 1;
                continue :sw ip[0].op;
            }
            st[sp] = x;
            st[sp + 1] = y;
            vs.items.len = sp + 2;
            return slow(m, code, ip, 2);
        },
        .prim1, .prim2 => {
            const p = code.prims[ip[0].a];
            const unary = ip[0].op == .prim1;
            const r = if (unary) rt.fast1(p.op, st[sp - 1]) else rt.fast(p.op, st[sp - 2], st[sp - 1]);
            const v = r orelse {
                vs.items.len = sp;
                return slow(m, code, ip, if (unary) 1 else 2);
            };
            if (!unary) sp -= 1;
            st[sp - 1] = v;
            ip += 1;
            continue :sw ip[0].op;
        },
        .call => {
            vs.items.len = sp;
            const b = sp - ip[0].a - 1;
            if (st[b].is(.f)) if (st[b].asFn().f == .plain) { // a native that just computes a value: no need to leave
                const n = st[b].asFn();
                st[b] = try n.f.plain(n, st[b + 1 .. sp]);
                sp = b + 1;
                ip += 1;
                continue :sw ip[0].op;
            };
            if (st[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return call(m, b, code, (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(rt.Ins) + 1);
        },
        .tailcall => {
            const b = sp - ip[0].a - 1;
            const f = st[b];
            if (f.is(.lam)) { // a function calling itself in tail position, in a scope nothing else holds: it runs again in that scope
                const l = f.asLam();
                if (e.proto == l.proto and e.p == l.env and !e.captured and !l.proto.rest) {
                    const np = l.proto.params.len;
                    for (e.vars[0..np], 0..) |*x, i| x.v = if (i < ip[0].a) st[b + 1 + i] else V.nil;
                    for (e.vars[np..code.keys.len]) |*x| x.v = V.nil; // its defines start unbound
                    sp = b;
                    ip = code.ins.ptr;
                    if (gc.due()) {
                        vs.items.len = sp;
                        gc.collect();
                    }
                    continue :sw ip[0].op;
                }
            }
            vs.items.len = sp;
            if (f.is(.f)) if (f.asFn().f == .plain) { // as in a call, and then return its value
                const n = f.asFn();
                const v = try n.f.plain(n, st[b + 1 .. sp]);
                vs.items.len = b;
                return .{ .ret = v };
            };
            if (st[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return .{ .apply = b };
        },
        .ret => {
            if (depth > 0) { // the body of a loop run here is done: back to the loop, which keeps its frame
                depth -= 1;
                const k = ks.items[ks.items.len - 1];
                const v = st[sp - 1];
                e = k.e;
                m.e = e;
                code = k.code;
                ip = code.ins.ptr + k.i;
                sp = k.base;
                st[sp] = v;
                sp += 1;
                continue :sw ip[0].op;
            }
            vs.items.len = sp - 1;
            return .{ .ret = st[sp - 1] };
        },
        .each => { // the list is on the stack: add the index and a place for the body's value
            st[sp] = V.num(-1);
            st[sp + 1] = V.nil;
            sp += 2;
            ip += 1;
            continue :sw ip[0].op;
        },
        .map => { // as each, with the list of results (the body's values) between the index and that place
            st[sp] = V.num(-1);
            st[sp + 1] = rt.list(&.{}, rt.items(st[sp - 1]).len);
            st[sp + 2] = V.nil;
            sp += 3;
            ip += 1;
            continue :sw ip[0].op;
        },
        .global => { // a name of an inlined function's body: only the global scope is looked at
            const r = code.refs[ip[0].a];
            if (r.g == null) r.g = rt.slotOf(rt.root, r.sym.key);
            st[sp] = if (r.g) |p| p.* else V.nil;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .setglobal => {
            const d = code.defs[ip[0].a];
            if (d.g == null) d.g = rt.slotOf(rt.root, d.sym.?.key);
            if (d.g) |p| {
                if (rt.compiledInto(p.*)) rt.epoch +%= 1;
                p.* = st[sp - 1];
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .storelocal => {
            e.vars[ip[0].a].v = st[sp - 1];
            sp -= 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .eachnext, .mapnext => |op| { // [list, index, (results,) body value]: the next iteration, or the end of the loop
            const is_map = op == .mapnext;
            const top = sp - 1;
            const ib = if (is_map) top - 2 else top - 1; // the index
            const idx = st[ib].asNum() + 1;
            const items = rt.items(st[ib - 1]);
            if (is_map and idx > 0) st[ib + 1].asList().items()[@intFromFloat(idx - 1)] = st[top];
            if (idx >= @as(f64, @floatFromInt(items.len))) { // done: the value of the loop is nil (each) or the results (map)
                if (idx > 0) { // there is a loop frame
                    const k = &ks.items[ks.items.len - 1];
                    if (k.env2) |x| if (!x.captured) rt.release(x);
                    ks.items.len -= 1;
                }
                st[ib - 1] = if (is_map) st[ib + 1] else V.nil;
                sp = ib;
                ip += 1;
                continue :sw ip[0].op;
            }
            if (idx == 0) {
                const k = rt.frame(.loop, &.{}, e);
                k.i = (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(rt.Ins);
                k.base = top;
                k.code = code;
            }
            const k = &ks.items[ks.items.len - 1];
            st[ib] = V.num(idx);
            if (!lang.in_macro and gc.due()) {
                vs.items.len = sp;
                gc.collect();
            }
            const body = code.bodies[ip[0].a].?;
            const item = items[@intFromFloat(idx)];
            if (k.env2) |x| if (!x.captured and x.vars.len == body.keys.len) { // nothing holds the scope of the last iteration: use it again
                x.vars[0].v = item;
                for (x.vars[1..]) |*v| v.v = V.nil;
                e = x;
            } else {
                k.env2 = null;
                var lam: rt.Lam = .{ .proto = code.protos[ip[0].a], .env = e };
                e = rt.bindWith(&lam, &.{item}, body);
            } else {
                var lam: rt.Lam = .{ .proto = code.protos[ip[0].a], .env = e };
                e = rt.bindWith(&lam, &.{item}, body);
            }
            k.env2 = e;
            m.e = e;
            depth += 1;
            code = body;
            ip = code.ins.ptr;
            sp = top;
            if (vs.capacity < top + code.room) {
                vs.items.len = sp;
                vs.ensureTotalCapacity(rt.gpa, top + code.room) catch gc.oom();
                st = vs.items.ptr;
            }
            continue :sw ip[0].op;
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
