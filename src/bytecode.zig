// Tier 2, the compiler: the body of a function becomes, on its first call, a stack bytecode, and the function's parameters
// and defines get fixed slots in its scope (scope.bind creates them all up front). vm.zig runs the bytecode. Anything this
// compiler does not know (a body nested too deep, a define that may not run, an error while expanding macros) leaves the
// function to the tree evaluator, which stays the reference semantics.
const std = @import("std");
const gc = @import("runtime/gc.zig");
const rt = @import("runtime/runtime.zig");
const scope = @import("runtime/scope.zig");
const prims = @import("runtime/primitives.zig");
const compile = @import("lang/compile.zig");
const V = rt.V;
const Node = rt.Node;
const E = rt.E;
const Op = Opcode;

// zig fmt: off
/// The instructions. a, b: the operands in the instruction (Ins); "push", "pop" and "top" are about the stack of values.
pub const Opcode = enum(u8) {
    // values
    konst,      // push consts[a]
    local,      // push slot a of the scope
    outer,      // push the variable refs[a], which is in an enclosing scope or global (b: where it was found, see vm.outerSlot)
    global,     // push the global refs[a] (a free name of an inlined function)
    lambda,     // push a closure of protos[a] over the scope
    // assignments (define and set! have a value, so it stays on the stack)
    setlocal,   // slot a = top
    setouter,   // define or set! defs[a], a name outside this function's slots (b as in outer)
    setglobal,  // set! the global defs[a]
    storelocal, // slot a = pop (an argument of an inlined function)
    pop,
    // control
    jmp,        // go to instruction b
    jmpf,       // pop; go to b if it was false
    andj, orj,  // && and ||: if top decides the result (false for &&, true for ||) go to b, else pop
    call,       // call the function that is under its a arguments; the value replaces them (consts[b]: its source, for an error)
    tailcall,   // the same in tail position: the call replaces this function's
    ret,        // return top
    // primitives, compiled while their names were bound to the natives. prims[a] is the call, made the ordinary way (vm.slow)
    // when the operands are not plain numbers (or a list and an index).
    not,        // top = (not top)
    prim1,      // top = (prims[a].op top): abs floor sqrt exp log cos
    add, sub, mul, div, mod, lt, gt, le, ge, eq, at, // pop y; top = (op top y)
    // The same, fused with the operands: the first is l (the local in slot b >> 16) or s (top of the stack), the second is
    // l (a local) or k (a constant), by its index in b's low 16 bits. The l forms push the value, the s forms replace top.
    add_lk, add_ll, sub_lk, sub_ll, mul_lk, mul_ll, lt_lk, lt_ll, gt_lk, gt_ll, le_lk, le_ll, ge_lk, ge_ll, eq_lk, eq_ll, at_lk, at_ll,
    add_sk, add_sl, sub_sk, sub_sl, mul_sk, mul_sl, lt_sk, lt_sl, gt_sk, gt_sl, le_sk, le_sl, ge_sk, ge_sl, eq_sk, eq_sl, at_sk, at_sl,
    vset,       // (vset! list index value) on the three top values; consts[a]: the native, which does all but an in-range store
    vset_ll,    // the same with the list in slot b >> 16 and the index in slot b & 0xffff: top stays, as the value
    // loops: (each list (lambda (x) ...)) and (map ...); protos[a] is the lambda, bodies[a] its bytecode.
    // b != 0: the list is (range n) and only n is on the stack, the loop counts.
    each, map,         // the list is on top: push the rest of the loop's state
    eachnext, mapnext, // run the body with the next item (it comes back here with `ret`), or end with the loop's value
};
// zig fmt: on

/// The instructions for a two-operand primitive, and those of them that have fused forms.
const binary = [_]Opcode{ .add, .sub, .mul, .div, .mod, .lt, .gt, .le, .ge, .eq, .at };
const fusable = [_]Opcode{ .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .at };

/// The primitive that a two-operand instruction, plain or fused, computes.
pub fn primOf(comptime op: Opcode) rt.Op {
    return switch (op) {
        .add, .add_lk, .add_ll, .add_sk, .add_sl => .@"+",
        .sub, .sub_lk, .sub_ll, .sub_sk, .sub_sl => .@"-",
        .mul, .mul_lk, .mul_ll, .mul_sk, .mul_sl => .@"*",
        .div => .@"/",
        .mod => .mod,
        .lt, .lt_lk, .lt_ll, .lt_sk, .lt_sl => .@"<",
        .gt, .gt_lk, .gt_ll, .gt_sk, .gt_sl => .@">",
        .le, .le_lk, .le_ll, .le_sk, .le_sl => .@"<=",
        .ge, .ge_lk, .ge_ll, .ge_sk, .ge_sl => .@">=",
        .eq, .eq_lk, .eq_ll, .eq_sk, .eq_sl => .@"eq?",
        .at, .at_lk, .at_ll, .at_sk, .at_sl => .at,
        else => unreachable,
    };
}

/// The fused form of op for the operands "lk", "ll", "sk" or "sl": add_lk for add.
fn fused(comptime op: Opcode, comptime operands: []const u8) Opcode {
    return @field(Opcode, @tagName(op) ++ "_" ++ operands);
}

/// Is the second operand of a fused instruction a constant (else a local)?
pub fn secondIsConst(comptime op: Opcode) bool {
    const name = @tagName(op);
    return name[name.len - 1] == 'k';
}

/// One instruction. a, b: its operands (see Opcode). An outer lookup also notes where it found the name in b, and the
/// `scope.shape` that was valid for in c.
pub const Ins = struct { op: Opcode, a: u16 = 0, b: u32 = 0, c: u32 = 0 };
/// The compiled body of a function. Instructions refer to the tables by index.
pub const Bytecode = struct {
    ins: []Ins,
    consts: []const V,
    refs: []const *rt.Ref, // names read outside this function's slots
    prims: []const *rt.Prim, // primitive calls, for the ordinary call when the operands are not plain numbers
    defs: []const *rt.Def, // define/set! of names outside this function's slots
    protos: []const *rt.Proto, // lambdas
    bodies: []const ?*Bytecode, // by the same index as protos: the compiled body of a loop lambda
    keys: []const rt.Key, // the names of the scope's slots: parameters, then defines, then the slots of inlined functions
    stamp: u32, // compile.current() when it was compiled
    room: usize, // the most values it can have on the stack
};

// Limits of what is compiled: past them a function stays with the tree evaluator, or a call is not inlined.
const max_depth = 120; // source nesting the compiler follows (it recurses)
const max_short_circuit_operands = 64; // of one && or ||
const max_plain_depth = 8; // nesting of the value in a vset_ll
const max_inline_depth = 24; // an inlined body: its nesting,
const max_inline_nodes = 48; // its size,
const max_inline_slots = 8; // and its parameters and defines
const max_inline_sites = 8; // calls inlined into one function

fn add(comptime T: type, list: *std.ArrayList(T), x: T) usize {
    list.append(rt.gpa, x) catch gc.oom();
    return list.items.len - 1;
}

/// The state of compiling one function: the tables of its Bytecode, then what the scan knows about its names.
const Compiler = struct {
    ins: std.ArrayList(Ins) = .empty,
    consts: std.ArrayList(V) = .empty,
    refs: std.ArrayList(*rt.Ref) = .empty,
    prims: std.ArrayList(*rt.Prim) = .empty,
    defs: std.ArrayList(*rt.Def) = .empty,
    protos: std.ArrayList(*rt.Proto) = .empty,
    bodies: std.ArrayList(?*Bytecode) = .empty, // by the same index: the compiled body of a loop lambda
    keys: std.ArrayList(rt.Key) = .empty,
    seen: std.ArrayList(rt.Key) = .empty, // names read or set! so far, in scan order
    conditional_depth: usize = 0, // > 0 while scanning code that may not run (the depth of such regions)
    held: std.ArrayList(struct { key: rt.Key, level: usize }) = .empty, // names defined in the regions being scanned
    closed: std.ArrayList(rt.Key) = .empty, // names defined in a region that is over: a later use would not be sure of the define
    self: ?*rt.Proto = null,
    inline_scope: ?struct { keys: []const rt.Key, base: usize } = null, // while an inlined function's body is generated: its names and where its slots start
    inline_sites: usize = 0, // functions inlined so far
    barrier: usize = 0, // the last jump target: instructions before it are not merged with the ones after

    fn emit(c: *Compiler, op: Op, a: usize, b: usize) usize {
        c.ins.append(rt.gpa, .{ .op = op, .a = @intCast(a), .b = @intCast(b) }) catch gc.oom();
        return c.ins.items.len - 1;
    }

    fn deinit(c: *Compiler) void {
        inline for (.{ &c.ins, &c.consts, &c.refs, &c.prims, &c.defs, &c.protos, &c.bodies, &c.keys, &c.seen, &c.held, &c.closed }) |list| list.deinit(rt.gpa);
    }

    fn slotOf(c: *Compiler, sym: *rt.Sym) ?usize {
        const keys = if (c.inline_scope) |i| i.keys else c.keys.items;
        const base = if (c.inline_scope) |i| i.base else 0;
        var i = keys.len; // the last of equal names wins, as in a scope search
        while (i > 0) : (i -= 1) if (keys[i - 1] == sym.key) return base + i - 1;
        return null;
    }

    fn forced(n: *Node) E!void {
        if (n.stamp != compile.current()) try compile.force(n);
    }

    /// A use of a name (a read or a set!). After a region that defined the name it cannot be compiled; otherwise it is
    /// remembered, so that a later define of the name is rejected.
    fn use(c: *Compiler, sym: *rt.Sym) !void {
        if (has(c.closed.items, sym)) return error.Bail;
        if (c.slotOf(sym) == null and !has(c.seen.items, sym)) _ = add(rt.Key, &c.seen, sym.key);
    }

    fn has(keys: []const rt.Key, sym: *rt.Sym) bool {
        for (keys) |k| if (k == sym.key) return true;
        return false;
    }

    /// The names a nested lambda reads or sets count as used where the lambda is made (it may run before a later define of
    /// the same name). Its own defines are not this function's: they get no slot here.
    fn scanUses(c: *Compiler, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val => {},
            .ref => |r| try c.use(r.sym),
            .@"if", .begin, .@"&&", .@"||", .call => |kids| for (kids) |k| try c.scanUses(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try c.scanUses(k, depth + 1),
            .def => |d| {
                try c.scanUses(d.val, depth + 1);
                if (!d.define) if (d.sym) |sym| try c.use(sym);
            },
            .lambda => |lp| try c.scanUses(lp.body, depth + 1),
            else => return error.Bail,
        }
    }

    /// Start of a region that may not run (a branch of an if, a later operand of && or ||).
    fn enter(c: *Compiler) void {
        c.conditional_depth += 1;
    }

    /// End of such a region: the names it defined can no longer be used (they are bound from the start of the call,
    /// but only defined if the region ran).
    fn leave(c: *Compiler) void {
        c.conditional_depth -= 1;
        while (c.held.items.len > 0 and c.held.items[c.held.items.len - 1].level > c.conditional_depth) {
            _ = add(rt.Key, &c.closed, c.held.items[c.held.items.len - 1].key);
            c.held.items.len -= 1;
        }
    }

    /// Find the defines of the body (they get slots) and reject what this tier does not do. A name a define adds is bound from the
    /// start of the call, so a define that may not run, or comes after a use of the same name (which would then mean an outer
    /// binding), is left to the tree evaluator, where the name is only bound once the define has run.
    fn scan(c: *Compiler, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val => {},
            .lambda => |lp| try c.scanUses(lp.body, depth + 1),
            .ref => |r| try c.use(r.sym),
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
                if (!d.define) return c.use(sym);
                if (has(c.closed.items, sym) or has(c.seen.items, sym)) return error.Bail;
                if (c.slotOf(sym) == null) _ = add(rt.Key, &c.keys, sym.key);
                if (c.conditional_depth > 0) _ = add(@TypeOf(c.held.items[0]), &c.held, .{ .key = sym.key, .level = c.conditional_depth });
                sym.local = true;
            },
            else => return error.Bail,
        }
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
                if (c.slotOf(r.sym)) |i| _ = c.emit(.local, i, 0) else _ = c.emit(if (c.inline_scope != null) .global else .outer, add(*rt.Ref, &c.refs, r), 0);
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
                    else => inline for (binary) |o| {
                        if (p.op == comptime primOf(o)) break o;
                    } else unreachable,
                };
                const pi = add(*rt.Prim, &c.prims, p);
                if (!c.fuse(op, pi)) _ = c.emit(op, pi, 0);
            },
            .lambda => |lp| {
                const at = add(*rt.Proto, &c.protos, lp);
                _ = add(?*Bytecode, &c.bodies, null);
                _ = c.emit(.lambda, at, 0);
            },
            .def => |d| {
                try c.gen(d.val, false);
                const slot = if (d.sym) |sym| c.slotOf(sym) else null;
                if (slot) |i| _ = c.emit(.setlocal, i, 0) else _ = c.emit(if (c.inline_scope != null) .setglobal else .setouter, add(*rt.Def, &c.defs, d), 0);
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
        const fused_op: Op = inline for (fusable) |o| {
            if (op == o) break if (first_local) (if (second_local) fused(o, "ll") else fused(o, "lk")) else (if (second_local) fused(o, "sl") else fused(o, "sk"));
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
        var sub: Compiler = .{};
        defer sub.deinit();
        for (l.proto.params) |pk| _ = add(rt.Key, &sub.keys, pk);
        sub.scan(l.proto.body, 0) catch return false;
        var count: usize = 0;
        if (!inlinable(l.proto.body, 0, &count) or sub.keys.items.len > max_inline_slots) return false;
        for (k[1..]) |x| try c.gen(x, false);
        const base = c.keys.items.len;
        for (sub.keys.items) |_| _ = add(rt.Key, &c.keys, rt.mkstr("(inlined)", true)); // slots no name finds
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
        const is_map = g.* == rt.map_v;
        if (!(is_map or g.* == rt.each_v) or lp.params.len != 1 or lp.rest) return false;
        const body = ready(lp) orelse return false;
        sym.inlined = true; // rebinding each or map makes epoch change, so this code is compiled again
        var counted: usize = 0;
        var source = k[1];
        if (k[1].code == .call and k[1].code.call.len == 2 and k[1].code.call[0].code == .ref) {
            const range = k[1].code.call[0].code.ref.sym;
            if (scope.globalOf(range)) |rg| if (rg.* == rt.range_v) {
                counted = 1;
                source = k[1].code.call[1];
                range.inlined = true; // rebinding range makes epoch change
            };
        }
        try c.gen(source, false);
        const at = add(*rt.Proto, &c.protos, lp);
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
        if (!prims.isVset(g.*)) return false;
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

fn build(p: *rt.Proto) void {
    p.tried = true;
    var c: Compiler = .{ .self = p };
    defer c.deinit();
    for (p.params) |k| _ = add(rt.Key, &c.keys, k);
    c.scan(p.body, 0) catch return;
    c.gen(p.body, true) catch return;
    const code = &rt.make(Bytecode, 1)[0];
    code.* = .{
        .ins = @constCast(dup(Ins, c.ins.items)),
        .consts = dup(V, c.consts.items),
        .refs = dup(*rt.Ref, c.refs.items),
        .prims = dup(*rt.Prim, c.prims.items),
        .defs = dup(*rt.Def, c.defs.items),
        .protos = dup(*rt.Proto, c.protos.items),
        .bodies = dup(?*Bytecode, c.bodies.items),
        .keys = dup(rt.Key, c.keys.items),
        .stamp = compile.current(),
        .room = room(c.ins.items),
    };
    for (code.consts) |v| _ = rt.pin(v);
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
    const m = rt.make(T, xs.len);
    @memcpy(m, xs);
    return m;
}

/// `make test-tree` builds with false: every function stays with the tree evaluator, and the tests must still pass.
const enabled = true;

/// The bytecode of p, compiled on first use and again after a macro changed; null if p stays with the tree evaluator.
pub fn ready(p: *rt.Proto) ?*Bytecode {
    if (!enabled or compile.in_macro) return null;
    if (p.code) |c| {
        if (c.stamp == compile.current()) return c;
        p.code = null;
        p.tried = false;
    }
    if (!p.tried) build(p);
    return p.code;
}
