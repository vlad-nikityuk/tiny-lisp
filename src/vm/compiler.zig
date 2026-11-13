// Tier 2, the compiler (after scan.zig has found the slots): the body of a function becomes, on its first call, a stack bytecode, and the function's parameters
// and defines get fixed slots in its scope (scope.bind creates them all up front). exec.zig runs the bytecode. Anything this
// compiler does not know (a body nested too deep, a define that may not run, an error while compiling a node) leaves the
// function to the tree evaluator, which stays the reference semantics.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const node = @import("../runtime/node.zig");
const primitives = @import("../runtime/primitives.zig");
const compile = @import("../lang/compile.zig");
const bytecode = @import("bytecode.zig");
const Scan = @import("scan.zig").Scan;
const V = value.V;
const Node = node.Node;
const Op = bytecode.Opcode;
const Ins = bytecode.Ins;
const Bytecode = bytecode.Bytecode;

// Limits of what is compiled: past them a function stays with the tree evaluator, or a call is not inlined.
const max_short_circuit_operands = 64; // of one && or ||
const max_plain_depth = 8; // nesting of the value in a vset_ll
const max_inline_depth = 24; // an inlined body: its nesting,
const max_inline_nodes = 48; // its size,
const max_inline_slots = 8; // and its parameters and defines
const max_inline_sites = 8; // calls inlined into one function

fn add(comptime T: type, list: *std.ArrayList(T), x: T) usize {
    list.append(value.gpa, x) catch gc.oom();
    return list.items.len - 1;
}

/// The state of generating the code of one function: the tables of its Bytecode, and where it is.
const Compiler = struct {
    ins: std.ArrayList(Ins) = .empty,
    consts: std.ArrayList(V) = .empty,
    refs: std.ArrayList(*node.Ref) = .empty,
    prims: std.ArrayList(*node.Prim) = .empty,
    defs: std.ArrayList(*node.Def) = .empty,
    protos: std.ArrayList(*node.Proto) = .empty,
    bodies: std.ArrayList(?*Bytecode) = .empty, // by the same index: the compiled body of a loop lambda
    keys: std.ArrayList(node.Key) = .empty, // the names of the slots: what the scan found, then the slots of inlined functions
    self: ?*node.Proto = null,
    inline_scope: ?struct { keys: []const node.Key, base: usize } = null, // while an inlined function's body is generated: its names and where its slots start
    inline_sites: usize = 0, // functions inlined so far
    barrier: usize = 0, // the last jump target: instructions before it are not merged with the ones after

    fn emit(c: *Compiler, op: Op, a: usize, b: usize) usize {
        c.ins.append(value.gpa, .{ .op = op, .a = @intCast(a), .b = @intCast(b) }) catch gc.oom();
        return c.ins.items.len - 1;
    }

    fn deinit(c: *Compiler) void {
        inline for (.{ &c.ins, &c.consts, &c.refs, &c.prims, &c.defs, &c.protos, &c.bodies, &c.keys }) |list| list.deinit(value.gpa);
    }

    fn slotOf(c: *Compiler, sym: *node.Sym) ?usize {
        const keys = if (c.inline_scope) |i| i.keys else c.keys.items;
        const base = if (c.inline_scope) |i| i.base else 0;
        var i = keys.len; // the last of equal names wins, as in a scope search
        while (i > 0) : (i -= 1) if (keys[i - 1] == sym.key) return base + i - 1;
        return null;
    }

    fn patch(c: *Compiler, at: usize) void {
        c.barrier = c.ins.items.len;
        c.ins.items[at].b = @intCast(c.ins.items.len);
    }

    /// Code that leaves the value of n on the stack; in tail position it returns it (or tail-calls) instead.
    fn gen(c: *Compiler, n: *Node, tail: bool) error{Bail}!void {
        switch (n.code) {
            // if, begin and calls pass the tail position on
            .@"if" => |k| {
                try c.gen(k[0], false);
                const jf = c.emit(.jmpf, 0, 0);
                try c.gen(k[1], tail);
                const j = if (tail) 0 else c.emit(.jmp, 0, 0);
                c.patch(jf);
                try c.gen(k[2], tail);
                if (!tail) c.patch(j);
                return;
            },
            .begin => |k| {
                for (k[0 .. k.len - 1]) |s| {
                    try c.gen(s, false);
                    _ = c.emit(.pop, 0, 0);
                }
                return c.gen(k[k.len - 1], tail);
            },
            .call => |k| return c.genCall(k, tail),
            // the rest leave a value, which a tail position returns
            .val => |v| _ = c.emit(.konst, add(V, &c.consts, v), 0),
            .ref => |*r| {
                if (c.slotOf(r.sym)) |i| _ = c.emit(.local, i, 0) else _ = c.emit(if (c.inline_scope != null) .global else .outer, add(*node.Ref, &c.refs, r), 0);
            },
            .@"&&", .@"||" => |k| {
                var jumps: [max_short_circuit_operands]usize = undefined;
                if (k.len > jumps.len) return error.Bail;
                for (k[0 .. k.len - 1], 0..) |x, i| {
                    try c.gen(x, false);
                    jumps[i] = c.emit(if (n.code == .@"&&") .andj else .orj, 0, 0);
                }
                try c.gen(k[k.len - 1], false);
                for (jumps[0 .. k.len - 1]) |at| c.patch(at);
            },
            .prim => |p| {
                if (p.sym.local or p.g.* != p.f) return c.genCall(p.c, tail); // rebound since it was compiled: an ordinary call
                for (p.c[1..]) |x| try c.gen(x, false);
                const op: Op = switch (p.op) {
                    .not => .not,
                    .abs, .floor, .sqrt, .exp, .log, .cos => .prim1,
                    else => inline for (bytecode.binary) |o| {
                        if (p.op == comptime bytecode.primOf(o)) break o;
                    } else unreachable,
                };
                const pi = add(*node.Prim, &c.prims, p);
                if (!c.fuse(op, pi)) _ = c.emit(op, pi, 0);
            },
            .lambda => |lp| {
                const at = add(*node.Proto, &c.protos, lp);
                _ = add(?*Bytecode, &c.bodies, null);
                _ = c.emit(.lambda, at, 0);
            },
            .def => |d| {
                try c.gen(d.val, false);
                const slot = if (d.sym) |sym| c.slotOf(sym) else null;
                if (slot) |i| _ = c.emit(.setlocal, i, 0) else _ = c.emit(if (c.inline_scope != null) .setglobal else .setouter, add(*node.Def, &c.defs, d), 0);
            },
            else => return error.Bail,
        }
        if (tail) _ = c.emit(.ret, 0, 0);
    }

    /// The operands just pushed: (op local local) and (op local constant) become one instruction (b: first slot << 16 | second);
    /// when the first operand is something else, a local or constant second operand still goes into the instruction (b: it).
    fn fuse(c: *Compiler, op: Op, pi: usize) bool {
        const n = c.ins.items.len;
        if (n == 0 or n - 1 < c.barrier) return false;
        const y = c.ins.items[n - 1];
        if (y.op != .local and y.op != .konst) return false;
        const first_local = n >= 2 and n - 2 >= c.barrier and c.ins.items[n - 2].op == .local;
        const second_local = y.op == .local;
        const fused_op: Op = inline for (bytecode.fusable) |o| {
            if (op == o) break if (first_local) (if (second_local) bytecode.fused(o, "ll") else bytecode.fused(o, "lk")) else (if (second_local) bytecode.fused(o, "sl") else bytecode.fused(o, "sk"));
        } else return false;
        if (first_local) {
            const x = c.ins.items[n - 2];
            c.ins.items.len = n - 2;
            _ = c.emit(fused_op, pi, (@as(usize, x.a) << 16) | y.a);
        } else {
            c.ins.items.len = n - 1;
            _ = c.emit(fused_op, pi, y.a);
        }
        return true;
    }

    /// Does evaluating this change nothing and call nothing (constants, names, primitives on those)?
    fn plain(n: *Node, depth: usize) bool {
        if (depth > max_plain_depth) return false;
        return switch (n.code) {
            .val, .ref => true,
            .prim => |p| if (p.sym.local or p.g.* != p.f) false else for (p.c[1..]) |x| { // (a rebound one is compiled as a call)
                if (!plain(x, depth + 1)) break false;
            } else true,
            else => false,
        };
    }

    /// Is this body something to inline: small, no closures?
    fn inlinable(n: *Node, depth: usize, count: *usize) bool {
        count.* += 1;
        if (depth > max_inline_depth or count.* > max_inline_nodes) return false;
        return switch (n.code) {
            .val, .ref => true,
            .call => |kids| calls: {
                if (kids[0].code != .ref or kids[0].code.ref.sym.local) break :calls false; // a function it is given may be load, which runs code in the scope it is called from
                if (scope.slotOf(scope.root, kids[0].code.ref.sym.key)) |g| {
                    if (g.*.is(.f) and g.*.asFn().f == .step) break :calls false; // so may a native that runs code (try, map...)
                }
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
    fn genInline(c: *Compiler, k: []const *Node, tail: bool) error{Bail}!bool {
        if (c.inline_scope != null or c.inline_sites >= max_inline_sites or k[0].code != .ref) return false;
        const g = scope.globalOf(k[0].code.ref.sym) orelse return false;
        if (!g.*.is(.lam)) return false;
        const l = g.*.asLam();
        if (l.env != scope.root or l.proto == c.self or l.proto.rest or l.proto.params.len != k.len - 1) return false;
        var sub: Scan = .{};
        defer sub.deinit();
        sub.function(l.proto) catch return false;
        var count: usize = 0;
        if (!inlinable(l.proto.body, 0, &count) or sub.keys.items.len > max_inline_slots) return false;
        for (k[1..]) |x| try c.gen(x, false);
        const base = c.keys.items.len;
        for (sub.keys.items) |_| _ = add(node.Key, &c.keys, value.mkstr("(inlined)", true)); // slots no name finds
        var i = k.len - 1;
        while (i > 0) : (i -= 1) _ = c.emit(.storelocal, base + i - 1, 0);
        l.proto.inlined = true;
        c.inline_scope = .{ .keys = sub.keys.items, .base = base };
        c.inline_sites += 1;
        defer c.inline_scope = null;
        try c.gen(l.proto.body, tail); // at a tail call site the body's own tail calls stay tail calls
        return true;
    }

    /// (each list (lambda (x) ...)) or (map list (lambda (x) ...)), while the name is the native: a loop of the bytecode, with
    /// the lambda's body compiled on its own. Over (range n) it counts to n and builds no list.
    fn genLoop(c: *Compiler, k: []const *Node) error{Bail}!bool {
        if (k.len != 3 or k[0].code != .ref or k[2].code != .lambda or k[2].guard == null) return false;
        const sym = k[0].code.ref.sym;
        const lp = k[2].code.lambda;
        const g = scope.globalOf(sym) orelse return false;
        const is_map = g.* == node.map_v;
        if (!(is_map or g.* == node.each_v) or lp.params.len != 1 or lp.rest) return false;
        const body = ready(lp) orelse return false;
        sym.inlined = true; // rebinding each or map makes epoch change, so this code is compiled again
        var counted: usize = 0;
        var source = k[1];
        if (k[1].code == .call and k[1].code.call.len == 2 and k[1].code.call[0].code == .ref) {
            const range = k[1].code.call[0].code.ref.sym;
            if (scope.globalOf(range)) |rg| if (rg.* == node.range_v) {
                counted = 1;
                source = k[1].code.call[1];
                range.inlined = true; // rebinding range makes epoch change
            };
        }
        try c.gen(source, false);
        const at = add(*node.Proto, &c.protos, lp);
        _ = add(?*Bytecode, &c.bodies, body);
        _ = c.emit(if (is_map) .map else .each, at, counted);
        _ = c.emit(if (is_map) .mapnext else .eachnext, at, counted);
        return true;
    }

    /// (vset! list index value), while vset! is the native: an instruction.
    fn genVset(c: *Compiler, k: []const *Node) error{Bail}!bool {
        if (k.len != 4 or k[0].code != .ref) return false;
        const sym = k[0].code.ref.sym;
        const g = scope.globalOf(sym) orelse return false;
        if (!primitives.isVset(g.*)) return false;
        sym.inlined = true; // rebinding it makes epoch change, so this code is compiled again
        const native = add(V, &c.consts, g.*);
        const list = if (k[1].code == .ref) c.slotOf(k[1].code.ref.sym) else null;
        const index = if (k[2].code == .ref) c.slotOf(k[2].code.ref.sym) else null;
        if (list != null and index != null and plain(k[3], 0)) { // the list and the index are locals: they need not be pushed
            try c.gen(k[3], false);
            _ = c.emit(.vset_ll, native, (list.? << 16) | index.?);
        } else {
            for (k[1..]) |x| try c.gen(x, false);
            _ = c.emit(.vset, native, 0);
        }
        return true;
    }

    fn genCall(c: *Compiler, k: []const *Node, tail: bool) error{Bail}!void {
        if (try c.genInline(k, tail)) return;
        if (try c.genLoop(k) or try c.genVset(k)) {
            if (tail) _ = c.emit(.ret, 0, 0);
            return;
        }
        for (k) |x| try c.gen(x, false);
        _ = c.emit(if (tail) .tailcall else .call, k.len - 1, add(V, &c.consts, k[0].ast));
    }
};

fn build(p: *node.Proto) void {
    p.tried = true;
    var c: Compiler = .{ .self = p };
    defer c.deinit();
    var names: Scan = .{};
    defer names.deinit();
    names.function(p) catch return;
    c.keys.appendSlice(value.gpa, names.keys.items) catch gc.oom();
    c.gen(p.body, true) catch return;
    const code = &node.make(Bytecode, 1)[0];
    code.* = .{
        .ins = @constCast(dup(Ins, c.ins.items)),
        .consts = dup(V, c.consts.items),
        .refs = dup(*node.Ref, c.refs.items),
        .prims = dup(*node.Prim, c.prims.items),
        .defs = dup(*node.Def, c.defs.items),
        .protos = dup(*node.Proto, c.protos.items),
        .bodies = dup(?*Bytecode, c.bodies.items),
        .keys = dup(node.Key, c.keys.items),
        .stamp = compile.current(),
        .room = room(c.ins.items),
    };
    for (code.consts) |v| _ = gc.pin(v);
    p.code = code;
}

/// The stack an instruction sequence needs at most: every instruction pushes one value or none, the start of a loop 3 or 4
/// (its state), and an instruction that falls back to the ordinary call pushes its two operands first.
fn room(ins: []const Ins) usize {
    var n: usize = 2;
    for (ins) |i| n += switch (i.op) {
        .map => 4,
        .each => 3,
        else => 1,
    };
    return n;
}

fn dup(comptime T: type, xs: []const T) []const T {
    const m = node.make(T, xs.len);
    @memcpy(m, xs);
    return m;
}

/// `make test-tree` builds with false: every function stays with the tree evaluator, and the tests must still pass.
const enabled = true;

/// The bytecode of p, compiled on first use and again after a rebound primitive made it out of date; null if p stays with the tree evaluator.
pub fn ready(p: *node.Proto) ?*Bytecode {
    if (!enabled) return null;
    if (p.code) |c| {
        if (c.stamp == compile.current()) return c;
        p.code = null;
        p.tried = false;
    }
    if (!p.tried) build(p);
    return p.code;
}
