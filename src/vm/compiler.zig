// The compiler (after scan.zig has found the slots): the nodes of a function become, on its first call, a stack bytecode, and the function's
// parameters and defines get fixed slots in its scope (scope.bind creates them all up front, the defines unbound). exec.zig runs the bytecode.
// Every function can be compiled: the only limit is how deep the code nests (compile.max_depth, checked when the nodes are built).
// A top-level form is compiled the same way, as a function without parameters that runs in the root scope (`top`): it has no slots,
// its names are globals and its defines create globals.
//
// A read of a name defined in the function is a plain `local` only where the define has certainly run (`defined`, below), else
// `local_checked`, which raises the use-before-define error.
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

// Limits of what is inlined or fused.
const max_plain_depth = 8; // nesting of the value in a vset_ll
const max_inline_depth = 24; // an inlined body: its nesting,
const max_inline_nodes = 48; // its size,
const max_inline_slots = 8; // and its parameters and defines
const max_inline_sites = 8; // calls inlined into one function

fn add(comptime T: type, list: *std.ArrayList(T), x: T) usize {
    list.append(value.gpa, x) catch gc.oom();
    return list.items.len - 1;
}

/// The primitive that a call computes in place: its head is a global (no scope binds the name) that is a primitive, with one operand if
/// the primitive is unary and two if not.
fn primitiveOf(k: []const *Node) ?primitives.Op {
    if ((k.len != 2 and k.len != 3) or k[0].code != .ref) return null;
    const op = primitives.primOp((scope.globalOf(k[0].code.ref.sym) orelse return null).*) orelse return null;
    return if ((k.len == 2) == primitives.unary(op)) op else null;
}

/// The state of generating the code of one function: the tables of its Bytecode, and where it is.
const Compiler = struct {
    ins: std.ArrayList(Ins) = .empty,
    consts: std.ArrayList(V) = .empty,
    refs: std.ArrayList(*node.Ref) = .empty,
    prims: std.ArrayList(bytecode.PrimCall) = .empty,
    defs: std.ArrayList(*node.Def) = .empty,
    protos: std.ArrayList(*node.Proto) = .empty,
    bodies: std.ArrayList(?*Bytecode) = .empty, // by the same index: the compiled body of a loop lambda
    keys: std.ArrayList(node.Key) = .empty, // the names of the slots: what the scan found, then the slots of inlined functions
    defined: std.ArrayList(bool) = .empty, // by slot: has the define (or a parameter's binding) certainly run at the code being generated? Code is generated in evaluation order; a branch or a later operand of && and || starts from what was certain before it and leaves nothing behind
    self: ?*node.Proto = null,
    top: bool = false, // a top-level form: no slots, defines are global
    inline_scope: ?struct { keys: []const node.Key, base: usize } = null, // while an inlined function's body is generated: its names and where its slots start
    inline_sites: usize = 0, // functions inlined so far
    barrier: usize = 0, // the last jump target: instructions before it are not merged with the ones after

    fn emit(c: *Compiler, op: Op, a: usize, b: usize) usize {
        c.ins.append(value.gpa, .{ .op = op, .a = @intCast(a), .b = @intCast(b) }) catch gc.oom();
        return c.ins.items.len - 1;
    }

    fn deinit(c: *Compiler) void {
        inline for (.{ &c.ins, &c.consts, &c.refs, &c.prims, &c.defs, &c.protos, &c.bodies, &c.keys, &c.defined }) |list| list.deinit(value.gpa);
    }

    fn slotOf(c: *Compiler, sym: *node.Sym) ?usize {
        const keys = if (c.inline_scope) |i| i.keys else c.keys.items;
        const base = if (c.inline_scope) |i| i.base else 0;
        var i = keys.len; // the last of equal names wins, as in a scope search
        while (i > 0) : (i -= 1) if (keys[i - 1] == sym.key) return base + i - 1;
        return null;
    }

    fn sure(c: *Compiler, slot: usize) bool {
        return c.defined.items[slot];
    }

    /// The state of `defined`, to come back to (the caller frees it).
    fn mark(c: *Compiler) []bool {
        return value.gpa.dupe(bool, c.defined.items) catch gc.oom();
    }

    fn restore(c: *Compiler, saved: []const bool) void {
        @memcpy(c.defined.items[0..saved.len], saved);
    }

    fn patch(c: *Compiler, at: usize) void {
        c.barrier = c.ins.items.len;
        c.ins.items[at].b = @intCast(c.ins.items.len);
    }

    /// Code that leaves the value of n on the stack; in tail position it returns it (or tail-calls) instead.
    fn gen(c: *Compiler, n: *Node, tail: bool) void {
        switch (n.code) {
            // if, begin and calls pass the tail position on
            .@"if" => |k| {
                c.gen(k[0], false);
                const before = c.mark();
                defer value.gpa.free(before);
                const jf = c.emit(.jmpf, 0, 0);
                c.gen(k[1], tail);
                const j = if (tail) 0 else c.emit(.jmp, 0, 0);
                const then_state = if (tail) before else c.mark(); // (in tail position nothing follows the if)
                defer if (!tail) value.gpa.free(then_state);
                c.restore(before);
                c.patch(jf);
                c.gen(k[2], tail);
                if (!tail) {
                    c.patch(j);
                    for (then_state, 0..) |sure_then, i| c.defined.items[i] = c.defined.items[i] and sure_then; // certain after either branch
                }
                return;
            },
            .begin => |k| {
                for (k[0 .. k.len - 1]) |s| {
                    c.gen(s, false);
                    _ = c.emit(.pop, 0, 0);
                }
                return c.gen(k[k.len - 1], tail);
            },
            .call => |k| return c.genCall(k, tail),
            // the rest leave a value, which a tail position returns
            .val => |v| _ = c.emit(.konst, add(V, &c.consts, v), 0),
            .ref => |*r| {
                if (c.slotOf(r.sym)) |i| {
                    if (c.sure(i)) _ = c.emit(.local, i, 0) else _ = c.emit(.local_checked, i, add(*node.Ref, &c.refs, r));
                } else _ = c.emit(if (c.inline_scope != null) .global else .outer, add(*node.Ref, &c.refs, r), 0);
            },
            .@"&&", .@"||" => |k| {
                var jumps: std.ArrayList(usize) = .empty; // one per operand but the last, however many there are
                defer jumps.deinit(value.gpa);
                c.gen(k[0], false);
                const first = c.mark(); // the later operands may not run
                defer value.gpa.free(first);
                for (k[1..]) |x| {
                    _ = add(usize, &jumps, c.emit(if (n.code == .@"&&") .andj else .orj, 0, 0));
                    c.gen(x, false);
                }
                c.restore(first);
                for (jumps.items) |at| c.patch(at);
            },
            .empty => _ = c.emit(.empty, 0, 0),
            .lambda => |lp| {
                const at = add(*node.Proto, &c.protos, lp);
                _ = add(?*Bytecode, &c.bodies, null);
                _ = c.emit(.lambda, at, 0);
            },
            .def => |d| {
                c.gen(d.val, false);
                const slot = if (d.sym) |sym| c.slotOf(sym) else null;
                if (slot) |i| {
                    _ = c.emit(.setlocal, i, 0);
                    c.defined.items[i] = true; // (set! of a slot that is still unbound assigns it)
                } else {
                    const op: Op = if (d.sym == null or d.define) .assign else if (c.inline_scope != null) .setglobal else .setouter;
                    _ = c.emit(op, add(*node.Def, &c.defs, d), 0);
                }
            },
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
            .call => |k| if (primitiveOf(k) == null) false else for (k[1..]) |x| {
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
                if (kids[0].code != .ref or kids[0].code.ref.sym.local) break :calls false; // a function it is given may be load, which runs code
                if (scope.slotOf(kids[0].code.ref.sym.key)) |g| {
                    if (g.*.is(.f) and g.*.asFn().f == .step) break :calls false; // so may a native that runs code (try, map...)
                }
                for (kids) |x| if (!inlinable(x, depth + 1, count)) break :calls false;
                break :calls true;
            },
            .@"if", .begin, .@"&&", .@"||" => |kids| for (kids) |x| {
                if (!inlinable(x, depth + 1, count)) break false;
            } else true,
            .def => |d| inlinable(d.val, depth + 1, count),
            .lambda, .empty => false,
        };
    }

    /// (f args...) where f is a small global function without closures: its body is generated here, with slots of its own for its
    /// parameters and defines and its free names read as globals. Redefining f compiles this code again (epoch).
    fn genInline(c: *Compiler, k: []const *Node, tail: bool) bool {
        if (c.top or c.inline_scope != null or c.inline_sites >= max_inline_sites or k[0].code != .ref) return false;
        const g = scope.globalOf(k[0].code.ref.sym) orelse return false;
        if (!g.*.is(.lam)) return false;
        const l = g.*.asLam();
        if (l.env != scope.root or l.proto == c.self or l.proto.rest or l.proto.params.len != k.len - 1) return false;
        var sub: Scan = .{};
        defer sub.deinit();
        sub.function(l.proto);
        var count: usize = 0;
        if (!inlinable(l.proto.body, 0, &count) or sub.keys.items.len > max_inline_slots) return false;
        for (k[1..]) |x| c.gen(x, false);
        const base = c.keys.items.len;
        for (sub.keys.items) |_| {
            _ = add(node.Key, &c.keys, value.mkstr("(inlined)", true)); // slots no name finds
            _ = add(bool, &c.defined, false); // unbound from the call's start: this site runs once per call
        }
        var i = k.len - 1;
        while (i > 0) : (i -= 1) {
            _ = c.emit(.storelocal, base + i - 1, 0);
            c.defined.items[base + i - 1] = true;
        }
        l.proto.inlined = true;
        c.inline_scope = .{ .keys = sub.keys.items, .base = base };
        c.inline_sites += 1;
        defer c.inline_scope = null;
        c.gen(l.proto.body, tail); // at a tail call site the body's own tail calls stay tail calls
        return true;
    }

    /// (each list (lambda (x) ...)) or (map list (lambda (x) ...)), while the name is the native: a loop of the bytecode, with
    /// the lambda's body compiled on its own. Over (range n) it counts to n and builds no list.
    fn genLoop(c: *Compiler, k: []const *Node) bool {
        if (k.len != 3 or k[0].code != .ref or k[2].code != .lambda) return false;
        const sym = k[0].code.ref.sym;
        const lp = k[2].code.lambda;
        const g = scope.globalOf(sym) orelse return false;
        const is_map = g.* == node.map_v;
        if (!(is_map or g.* == node.each_v) or lp.params.len != 1 or lp.rest) return false;
        const body = ready(lp);
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
        c.gen(source, false);
        const at = add(*node.Proto, &c.protos, lp);
        _ = add(?*Bytecode, &c.bodies, body);
        _ = c.emit(if (is_map) .map else .each, at, counted);
        _ = c.emit(if (is_map) .mapnext else .eachnext, at, counted);
        return true;
    }

    /// (vset! list index value), while vset! is the native: an instruction.
    fn genVset(c: *Compiler, k: []const *Node) bool {
        if (k.len != 4 or k[0].code != .ref) return false;
        const sym = k[0].code.ref.sym;
        const g = scope.globalOf(sym) orelse return false;
        if (!primitives.isVset(g.*)) return false;
        sym.inlined = true; // rebinding it makes epoch change, so this code is compiled again
        const native = add(V, &c.consts, g.*);
        const list = if (k[1].code == .ref) c.slotOf(k[1].code.ref.sym) else null;
        const index = if (k[2].code == .ref) c.slotOf(k[2].code.ref.sym) else null;
        if (list != null and index != null and c.sure(list.?) and c.sure(index.?) and plain(k[3], 0)) { // the list and the index are locals: they need not be pushed
            c.gen(k[3], false);
            _ = c.emit(.vset_ll, native, (list.? << 16) | index.?);
        } else {
            for (k[1..]) |x| c.gen(x, false);
            _ = c.emit(.vset, native, 0);
        }
        return true;
    }

    /// (f args...) where f is a global primitive with one or two operands: its instruction, fused with local and constant operands.
    fn genPrim(c: *Compiler, k: []const *Node, op: primitives.Op) void {
        const sym = k[0].code.ref.sym;
        sym.inlined = true; // rebinding it makes epoch change, so this code is compiled again
        for (k[1..]) |x| c.gen(x, false);
        const code: Op = switch (op) {
            .not => .not,
            .abs, .floor, .sqrt, .exp, .log, .cos => .prim1,
            else => inline for (bytecode.binary) |o| {
                if (op == comptime bytecode.primOf(o)) break o;
            } else unreachable,
        };
        const pi = add(bytecode.PrimCall, &c.prims, .{ .op = op, .sym = sym, .head = k[0].ast });
        if (!c.fuse(code, pi)) _ = c.emit(code, pi, 0);
    }

    /// The lambda that is the last operand of a call of each or map gets a guard: if the name is still the global native when the
    /// lambda is made, making it captures nothing (scope.lambda). (A loop that genLoop compiles never makes the lambda.)
    fn guardLoopBody(k: []const *Node) void {
        const last = k[k.len - 1];
        if (k.len < 3 or k[0].code != .ref or last.code != .lambda or last.code.lambda.guard != null) return;
        const sym = k[0].code.ref.sym;
        const g = scope.globalOf(sym) orelse return;
        if (g.* != node.each_v and g.* != node.map_v) return;
        const guard = &node.make(node.Guard, 1)[0];
        guard.* = .{ .sym = sym, .g = g, .f = gc.pin(g.*) };
        last.code.lambda.guard = guard;
    }

    fn genCall(c: *Compiler, k: []const *Node, tail: bool) void {
        if (c.genInline(k, tail)) return;
        guardLoopBody(k);
        if (c.genLoop(k) or c.genVset(k)) {
            if (tail) _ = c.emit(.ret, 0, 0);
            return;
        }
        if (primitiveOf(k)) |op| {
            c.genPrim(k, op);
            if (tail) _ = c.emit(.ret, 0, 0);
            return;
        }
        for (k) |x| c.gen(x, false);
        _ = c.emit(if (tail) .tailcall else .call, k.len - 1, add(V, &c.consts, k[0].ast));
    }
};

/// The bytecode with the tables of c.
fn finish(c: *const Compiler) *Bytecode {
    const code = &node.make(Bytecode, 1)[0];
    code.* = .{
        .ins = @constCast(dup(Ins, c.ins.items)),
        .consts = dup(V, c.consts.items),
        .refs = dup(*node.Ref, c.refs.items),
        .prims = dup(bytecode.PrimCall, c.prims.items),
        .defs = dup(*node.Def, c.defs.items),
        .protos = dup(*node.Proto, c.protos.items),
        .bodies = dup(?*Bytecode, c.bodies.items),
        .keys = dup(node.Key, c.keys.items),
        .stamp = scope.epoch,
        .room = room(c.ins.items),
    };
    for (code.consts) |v| _ = gc.pin(v);
    return code;
}

/// The body of p compiled.
fn build(p: *node.Proto) *Bytecode {
    var c: Compiler = .{ .self = p };
    defer c.deinit();
    var names: Scan = .{};
    defer names.deinit();
    names.function(p);
    c.keys.appendSlice(value.gpa, names.keys.items) catch gc.oom();
    for (c.keys.items, 0..) |_, i| _ = add(bool, &c.defined, i < p.params.len); // parameters are bound; the defines are not yet
    c.gen(p.body, true);
    const code = finish(&c);
    p.code = code; // (the epoch may have changed while the body was scanned and compiled: the stamp is the one at the end)
    return code;
}

/// The code of a top-level form, already expanded (expand.zig): a function without parameters, to be run in the root scope.
pub fn top(x: V) value.E!*Bytecode {
    const body = try compile.top(x);
    var c: Compiler = .{ .top = true };
    defer c.deinit();
    c.gen(body, true);
    return finish(&c);
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

/// The bytecode of p, compiled on first use and again after a rebound primitive made it out of date.
pub fn ready(p: *node.Proto) *Bytecode {
    if (p.code) |c| if (c.stamp == scope.epoch) return c;
    return build(p);
}
