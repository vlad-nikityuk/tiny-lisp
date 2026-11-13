const std = @import("std");
const gc = @import("gc.zig");
const lang = @import("lang.zig");
const prims = @import("primitives.zig");
pub const Op = prims.Op;

pub const E = error{Lisp}; // the error value itself is in `errv`
/// A value in 8 bytes (NaN boxing): a number is its own double bits, everything else lives in the quiet-NaN space with a
/// 3-bit tag in bits 48-50 and a 48-bit pointer or flag as payload. Numbers that are NaN are stored as one canonical NaN.
pub const V = enum(u64) {
    _,
    pub const Tag = enum { n, nil, b, s, lit, l, f, lam }; // s: symbol or runtime string, lit: string literal from source
    const BOX: u64 = 0xFFF8_0000_0000_0000;
    const PAYLOAD: u64 = 0x0000_FFFF_FFFF_FFFF;
    pub const nil: V = @fromBackingInt(@intCast(BOX | 1 << 48));

    inline fn box(t: u64, payload: u64) V {
        return @fromBackingInt(@intCast(BOX | t << 48 | payload));
    }
    inline fn bits(v: V) u64 {
        return @backingInt(v);
    }
    inline fn addr(v: V) usize {
        return @intCast(v.bits() & PAYLOAD);
    }
    pub inline fn num(x: f64) V {
        return if (x != x) @fromBackingInt(@intCast(0x7FF8_0000_0000_0000)) else @fromBackingInt(@intCast(@as(u64, @bitCast(x))));
    }
    pub inline fn boolean(x: bool) V {
        return box(2, @intFromBool(x));
    }
    pub inline fn string(p: [*:0]const u8) V {
        return box(3, @intFromPtr(p));
    }
    pub inline fn literal(p: [*:0]const u8) V {
        return box(4, @intFromPtr(p));
    }
    pub inline fn listOf(p: *Lst) V {
        return box(5, @intFromPtr(p));
    }
    pub inline fn fnOf(p: *Fn) V {
        return box(6, @intFromPtr(p));
    }
    pub inline fn lamOf(p: *Lam) V {
        return box(7, @intFromPtr(p));
    }
    pub inline fn tag(v: V) Tag {
        if (v.bits() >> 51 != 0x1FFF) return .n;
        return switch (v.bits() >> 48 & 7) {
            1 => .nil,
            2 => .b,
            3 => .s,
            4 => .lit,
            5 => .l,
            6 => .f,
            7 => .lam,
            else => .n,
        };
    }
    pub inline fn isNum(v: V) bool {
        return v.bits() >> 51 != 0x1FFF;
    }
    pub inline fn is(v: V, t: Tag) bool {
        return v.tag() == t;
    }
    pub inline fn asNum(v: V) f64 {
        return @bitCast(v.bits());
    }
    pub inline fn asBool(v: V) bool {
        return v.bits() & 1 != 0;
    }
    pub inline fn asStr(v: V) [*:0]const u8 { // for s and lit
        return @ptrFromInt(v.addr());
    }
    pub inline fn asList(v: V) *Lst {
        return @ptrFromInt(v.addr());
    }
    pub inline fn asFn(v: V) *Fn {
        return @ptrFromInt(v.addr());
    }
    pub inline fn asLam(v: V) *Lam {
        return @ptrFromInt(v.addr());
    }

    /// Iterative, so nested lists can't overflow the native stack.
    pub fn format(top: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var todo: std.ArrayList(?V) = .empty; // null: a list's closing parenthesis
        defer todo.deinit(std.heap.c_allocator);
        gc.push(?V, &todo, top);
        while (todo.pop()) |item| {
            if (item) |v| switch (v.tag()) {
                .nil => try w.writeAll("nil"),
                .b => try w.writeAll(if (v.asBool()) "#t" else "#f"),
                .n => {
                    const n = v.asNum();
                    if (n == @trunc(n) and @abs(n) < 1e18) try w.print("{d}", .{@as(i64, @intFromFloat(n))}) else try w.print("{d}", .{n});
                },
                .s => try w.writeAll(std.mem.span(v.asStr())),
                .lit => try w.print("\"{s}\"", .{v.asStr()}),
                .l => {
                    try w.writeByte('(');
                    gc.push(?V, &todo, null);
                    var it = std.mem.reverseIterator(v.asList().items());
                    while (it.next()) |x| gc.push(?V, &todo, x);
                    continue;
                },
                .f, .lam => try w.writeAll("<function>"),
            } else try w.writeByte(')');
            if (todo.getLastOrNull()) |next| if (next != null) try w.writeByte(' '); // more items of the same list
        }
    }
};
/// A list: its items are stored inline, right after the length.
pub const Lst = struct {
    len: usize,
    pub inline fn items(self: *Lst) []V {
        return gc.after(V, self)[0..self.len];
    }
};
/// A native function. d0, d1: its own data (the function and the fixed arguments of a partial, say); i: the trampoline's state.
pub const Fn = struct { f: Native, d0: V, d1: V, i: usize = 0 };
/// plain: computes its value directly. step: calls back into Lisp, so it runs as a frame of the machine: it is
/// invoked with null first, then with each callback's value, and says what the machine does next.
pub const Native = union(enum) { plain: *const fn (*Fn, []const V) E!V, step: *const fn (*Fn, *Frame, ?V) E!Go };
/// A closure: code and the scope it was made in.
pub const Lam = struct { proto: *Proto, env: *Env };
/// A scope: the variables of one call. The root scope has none: its names are in the global table.
pub const Env = struct {
    p: ?*Env, // the enclosing scope
    vars: []Var, // stored inline, right after the Env, until they outgrow cap
    cap: usize,
    proto: ?*Proto = null, // the function whose call this is
    recyclable: bool = false, // `release` may hand it to a free list: it has a pooled size, no closure holds it or an inner scope, and it is not on a list yet
    captured: bool = false, // a closure holds it or an inner scope: a loop or a self tail call must not use it again
};
pub const Var = struct { k: Key, v: V };

// Compiled code (see the compiler in lang.zig). Nodes and their arrays live forever, so frames and closures can keep pointing at them.
pub const Key = [*:0]const u8; // a symbol, interned: equal names are the same pointer
pub const Sym = struct {
    key: Key,
    local: bool = false, // some scope binds this name (a parameter, or a define inside a function); otherwise it can only be global
    inlined: bool = false, // compiled code relies on the global value of this name (a primitive, each, map, range): binding it locally bumps epoch
};
/// A call of a primitive with one or two operands, compiled as such while its name is global and still bound to that primitive.
/// The evaluator computes it in place when each operand is a constant, a variable or (a few levels deep) another such call, and the
/// values are numbers (or a list and an index); otherwise it makes the ordinary call c. slow: an operand cannot be computed that way.
pub const Prim = struct { op: Op, sym: *Sym, g: *V, f: V, c: []const *Node, slow: bool = false };
pub const Ref = struct { sym: *Sym, g: ?*V = null }; // g: the global slot, once found
pub const Def = struct { sym: ?*Sym, g: ?*V = null, val: *Node, define: bool }; // define or set!
/// The code of a lambda, shared by the closures made from it.
pub const Proto = struct {
    params: []const Key,
    body: *Node,
    cap: usize = 0, // room for the scope of a call, grown by defines
    rest: bool = false, // the last parameter takes the extra arguments as a list
    guard: ?*Guard = null,
    code: ?*Bytecode = null, // the tier-2 form of the body (vm.zig)
    tried: bool = false, // tier 2 compiled the body or rejected it (a rejected body is not tried again)
    inlined: bool = false, // other functions' bytecode contains this body: replacing the function bumps epoch
};
pub const Code = union(enum) { raw, val: V, ref: Ref, @"if": []const *Node, begin: []const *Node, def: *Def, lambda: *Proto, prim: *Prim, @"&&": []const *Node, @"||": []const *Node, call: []const *Node };
/// Tier 2 (vm.zig): a function body as a stack bytecode over fixed scope slots (keys: parameters, then defines).
pub const Opcode = enum(u8) { konst, local, outer, setlocal, setouter, pop, jmp, jmpf, andj, orj, lambda, vset, each, eachnext, map, mapnext, global, setglobal, storelocal, not, mod, div, add, sub, mul, lt, gt, le, ge, eq, at, add_lk, add_ll, sub_lk, sub_ll, mul_lk, mul_ll, lt_lk, lt_ll, gt_lk, gt_ll, le_lk, le_ll, ge_lk, ge_ll, eq_lk, eq_ll, at_lk, at_ll, add_sk, add_sl, sub_sk, sub_sl, mul_sk, mul_sl, lt_sk, lt_sl, gt_sk, gt_sl, le_sk, le_sl, ge_sk, ge_sl, eq_sk, eq_sl, at_sk, at_sl, vset_ll, prim1, call, tailcall, ret };
pub const Ins = struct { op: Opcode, a: u16 = 0, b: u32 = 0, c: u32 = 0 }; // an outer lookup notes where it found the name in b, and the `shape` it was valid for in c
pub const Bytecode = struct { ins: []Ins, consts: []const V, refs: []const *Ref, prims: []const *Prim, defs: []const *Def, protos: []const *Proto, bodies: []const ?*Bytecode, keys: []const Key, stamp: u32, room: usize };
/// The lambda that is the last operand of a call of each or map (while that name is still global and the native): the native only
/// calls it, so creating it does not capture its scope (lambda below).
pub const Guard = struct { sym: *Sym, g: *V, f: V };
/// One expression. Its code is built from the AST when it is first evaluated, and again when `stamp` is out of date.
pub const Node = struct {
    ast: V,
    src: V = .nil, // the (macro-expanded) form that code was built from
    stamp: u32 = 0, // lang.current() when code was built; 0: never
    code: Code = .raw,
    guard: ?*Guard = null, // set on the lambda operand of each/map
};

pub const gpa = std.heap.c_allocator;

// The machine's state: pending work lives in heap frames, so nothing grows the native stack.
pub const Form = enum { quote, lambda, @"if", begin, define, @"set!", @"&&", @"||", apply }; // apply: anything else
pub const Kind = enum { @"if", @"&&", @"||", begin, def, call, native, vm, loop };
/// Pending work: what to do with the next value. One flat struct for every kind (a frame is pushed per call, so it stays small
/// and is written in one go); each kind uses the fields it needs.
pub const Frame = struct {
    kind: Kind,
    i: usize, // begin, &&, ||, call: the item being evaluated; native: its own state; vm, loop: the instruction to resume at
    base: usize, // call, native: where the function and its arguments start on vs; vm, loop: the top of vs to return to
    c: []const *Node, // if, begin, &&, ||, call: the items
    d: *Def = undefined, // def
    e: *Env, // the scope to go back to
    code: *Bytecode = undefined, // vm, loop: the bytecode to resume
    iter_env: ?*Env = null, // loop: the scope of the iteration that is running, which the next one reuses if nothing captured it
};
/// A running evaluator loop: its scope is a root for the collector. ks[base..] are its frames.
pub const Machine = struct { e: *Env, base: usize };
pub var machines: std.ArrayList(*Machine) = .empty;
/// Values that permanent compiled nodes point to (the AST and its expansions) stay alive for good.
pub var pins: std.ArrayList(V) = .empty;

pub fn pin(v: V) V {
    gc.push(V, &pins, v);
    return v;
}
/// What the machine does next. eval: evaluate a node; ret: hand a value to the innermost frame; vm: run bytecode from pc;
/// apply: call the function at vs[apply] with the arguments after it; args: collect a call's items from c[i] on, they start at vs[b].
pub const Go = union(enum) { eval: *Node, ret: V, vm: struct { code: *Bytecode, pc: usize }, apply: usize, args: struct { c: []const *Node, i: usize, b: usize } };

pub var ks: std.ArrayList(Frame) = .empty; // the frames
pub var vs: std.ArrayList(V) = .empty; // the values: functions and arguments being collected, native frames' state, the bytecode's stack

pub fn frame(kind: Kind, c: []const *Node, e: *Env) *Frame {
    gc.push(Frame, &ks, .{ .kind = kind, .i = 0, .base = vs.items.len, .c = c, .e = e });
    return &ks.items[ks.items.len - 1];
}

/// Push the value of c[i], an item of a call: the function first, which must exist.
pub inline fn operand(c: []const *Node, i: usize, v: V) E!void {
    if (i == 0 and v == V.nil) return fail(str("TinyLisp: Function {f} is not defined", .{c[0].ast}));
    gc.push(V, &vs, v);
}

pub fn ptr(v: V) ?*anyopaque {
    return switch (v.tag()) {
        .nil, .b, .n => null,
        .s, .lit => @ptrCast(@constCast(v.asStr())),
        .l => v.asList(),
        .f => v.asFn(),
        .lam => v.asLam(),
    };
}

pub fn arg(a: []const V, i: usize) V {
    return if (i < a.len) a[i] else .nil;
}

pub fn items(v: V) []V {
    return if (v.is(.l)) v.asList().items() else &.{};
}

pub fn mkstr(s: []const u8, perm: bool) [*:0]u8 {
    const t: [*]u8 = @ptrCast(if (perm) gc.perm(s.len + 1) else gc.alloc(s.len + 1, .str));
    @memcpy(t[0..s.len], s);
    t[s.len] = 0;
    return @ptrCast(t);
}

pub fn str(comptime f: []const u8, args: anytype) V {
    const m = std.fmt.allocPrint(gpa, f, args) catch gc.oom();
    defer gpa.free(m);
    return V.string(mkstr(m, false));
}

pub fn fail(e: V) E {
    lang.errv = e;
    return error.Lisp;
}

/// A list of n items: a, then nils.
pub fn list(a: []const V, n: usize) V {
    const l = gc.new(Lst, n * @sizeOf(V), .list, .{ .len = n });
    for (l.items(), 0..) |*x, i| x.* = arg(a, i);
    return V.listOf(l);
}

pub fn nf(f: Native, d0: V, d1: V) *Fn {
    return gc.new(Fn, 0, .func, .{ .f = f, .d0 = d0, .d1 = d1 });
}

pub fn truthy(v: V) bool {
    return switch (v.tag()) {
        .nil => false,
        .b => v.asBool(),
        .n => v.asNum() != 0 and v.asNum() == v.asNum(),
        .s => v.asStr()[0] != 0,
        else => true,
    };
}

fn isNil(v: V) bool {
    return v == V.nil or (v.is(.l) and v.asList().len == 0);
}

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

pub fn eq(a: V, b: V) bool {
    if (isNil(a) or isNil(b)) return isNil(a) and isNil(b);
    if ((a.is(.s) and b.is(.s)) or (a.is(.lit) and b.is(.lit))) return streq(a.asStr(), b.asStr());
    if (a.isNum() and b.isNum()) return a.asNum() == b.asNum();
    return a == b;
}

pub fn num(v: V) f64 {
    return switch (v.tag()) {
        .n => v.asNum(),
        .b => @floatFromInt(@intFromBool(v.asBool())),
        .nil => 0,
        else => std.math.nan(f64),
    };
}

// scopes
// ----------------------------------------------------------------
pub var macros: std.ArrayList(*V) = .empty; // root slots of the macro/* functions
pub var gk: [1 << 13]?[*:0]const u8 = @splat(null); // globals: open addressing, FNV-1a
pub var gv: [1 << 13]V = @splat(.nil);

/// Bumped when a name is added to a scope whose layout tier-2 code relies on (by load, say): remembered lookups are void.
pub var shape: u32 = 1;
/// The natives each and map themselves (not a function that merely is a step native): the loop lambda exemption and the bytecode loops are for them.
pub var each_v: V = .nil;
pub var map_v: V = .nil;
pub var range_v: V = .nil; // the native range: a loop over a call of it counts instead of building the list

/// How many items (range v) has.
pub fn rangeLen(v: V) usize {
    return @intFromFloat(@max(0, num(v)));
}
pub var epoch: u32 = 0; // bumped when a macro/* changes: code compiled before it is compiled again

pub fn slotOf(e: *Env, k: Key) ?*V {
    return slot(e, k, false);
}

fn slot(e: *Env, k: Key, create: bool) ?*V {
    if (e.p == null) {
        var i: usize = std.hash.Fnv1a_32.hash(std.mem.span(k)) & (gk.len - 1);
        while (gk[i]) |key| : (i = (i + 1) & (gk.len - 1)) if (streq(key, k)) return &gv[i];
        if (create) gk[i] = k;
        return if (create) &gv[i] else null;
    }
    var i = e.vars.len; // the latest binding of a name wins
    while (i > 0) : (i -= 1) if (e.vars[i - 1].k == k) return &e.vars[i - 1].v;
    if (!create) return null;
    if (e.vars.len == e.cap) {
        const more = gpa.alloc(Var, e.cap * 2) catch gc.oom();
        @memcpy(more[0..e.cap], e.vars);
        if (e.vars.ptr != gc.after(Var, e)) gpa.free(e.vars);
        e.vars.ptr, e.cap = .{ more.ptr, more.len };
        if (e.proto) |p| p.cap = e.cap; // the next call of this function gets a scope that is big enough
    }
    if (e.proto != null and e.proto.?.code != null) {
        shape +%= 1;
    }
    e.vars.len += 1;
    e.vars[e.vars.len - 1] = .{ .k = k, .v = .nil };
    return &e.vars[e.vars.len - 1].v;
}

/// The innermost binding of the name: scope keys are interned, so they are compared by address. A name that no scope binds
/// is global without searching. g caches the global slot.
pub fn find(env: *Env, sym: *Sym, g: *?*V) ?*V {
    var e = env;
    while (sym.local and e.p != null) : (e = e.p.?) {
        var i = e.vars.len;
        while (i > 0) : (i -= 1) if (e.vars[i - 1].k == sym.key) return &e.vars[i - 1].v;
    }
    if (g.* == null) g.* = slot(root, sym.key, false);
    return g.*;
}

pub fn fetch(env: *Env, r: *Ref) V {
    return if (find(env, r.sym, &r.g)) |p| p.* else .nil;
}

pub fn assign(d: *Def, e: *Env, v: V) E!void {
    const sym = d.sym orelse return fail(str("TinyLisp: {s} needs a name", .{if (d.define) "define" else "set!"}));
    if (d.define) {
        if (sym.inlined and !sym.local and e.p != null) epoch +%= 1;
        sym.local = sym.local or e.p != null;
        set(e, sym.key, v);
    } else if (find(e, sym, &d.g)) |p| {
        if (compiledInto(p.*)) epoch +%= 1;
        p.* = v;
    }
}

/// Root keys are copied to permanent memory; scope keys are interned already.
pub fn set(e: *Env, key: Key, v: V) void {
    const s = slot(e, key, false) orelse blk: {
        const s = slot(e, if (e.p != null) key else mkstr(std.mem.span(key), true), true).?;
        if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) gc.push(*V, &macros, s);
        break :blk s;
    };
    if (e.p == null and compiledInto(s.*)) epoch +%= 1; // a native (maybe a primitive that tier-2 code inlines) or an inlined function is replaced
    s.* = v;
    if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) epoch +%= 1;
}

/// Replacing this value must compile the tier-2 code again: it is a native, or a function that other functions' code contains.
pub fn compiledInto(v: V) bool {
    return v.is(.f) or (v.is(.lam) and v.asLam().proto.inlined);
}

pub fn lambda(p: *Proto, e: *Env) V {
    if (p.guard) |d| if (!d.sym.local and d.g.* == d.f) return V.lamOf(gc.new(Lam, 0, .lam, .{ .proto = p, .env = e })); // a loop body: dead once the loop is over
    var s: ?*Env = e; // a closure holds the scope and, through it, the enclosing ones: none can be recycled when its call ends
    while (s) |x| : (s = x.p) {
        x.recyclable = false;
        x.captured = true;
    }
    return V.lamOf(gc.new(Lam, 0, .lam, .{ .proto = p, .env = e }));
}

// Most scopes die when their call ends: a call's scope is recycled then, unless a closure captured it. Recycled scopes wait on
// free lists by capacity (linked through `p`); the collector forgets the lists, so whatever they hold is simply collected.
const pool_caps = [_]usize{ 4, 8, 16 };
pub var env_pools: [pool_caps.len]?*Env = @splat(null);

fn poolOf(cap: usize) ?usize {
    return switch (cap) {
        4 => 0,
        8 => 1,
        16 => 2,
        else => null,
    };
}

/// The capacity a scope for n variables gets: one of the pooled sizes if it fits.
fn capFor(n: usize) usize {
    for (pool_caps) |c| if (n <= c) return c;
    return n;
}

pub fn bind(f: *Lam, a: []const V) *Env {
    return bindWith(f, a, f.proto.code);
}

/// The scope of a call of f; for tier-2 code (`code`), the defines of the body have their slots from the start.
pub fn bindWith(f: *Lam, a: []const V, code: ?*Bytecode) *Env {
    const ps = f.proto.params;
    const n = if (code) |c| c.keys.len else ps.len;
    const cap = capFor(@max(f.proto.cap, n));
    const pool = poolOf(cap);
    const e = if (pool != null and env_pools[pool.?] != null) blk: {
        const e = env_pools[pool.?].?;
        env_pools[pool.?] = e.p;
        break :blk e;
    } else gc.new(Env, cap * @sizeOf(Var), .env, undefined);
    e.* = .{ .p = f.env, .vars = gc.after(Var, e)[0..n], .cap = cap, .proto = f.proto, .recyclable = pool != null };
    const fixed = ps.len - @intFromBool(f.proto.rest); // a last parameter after & takes the extra arguments as a list
    for (ps[0..fixed], e.vars[0..fixed], 0..) |k, *x, i| x.* = .{ .k = k, .v = arg(a, i) };
    if (f.proto.rest) e.vars[fixed] = .{ .k = ps[fixed], .v = list(if (a.len > fixed) a[fixed..] else &.{}, a.len -| fixed) };
    if (code) |c| for (c.keys[ps.len..], e.vars[ps.len..]) |k, *x| {
        x.* = .{ .k = k, .v = .nil };
    };
    return e;
}

/// The call that ran in e is over (nothing but a closure could still use it).
pub fn release(e: *Env) void {
    if (!e.recyclable or e.p == null or e.vars.ptr != gc.after(Var, e)) return;
    const pool = poolOf(e.cap) orelse return;
    e.recyclable = false; // never twice
    e.p = env_pools[pool];
    env_pools[pool] = e;
}

// natives that call back into Lisp
// ----------------------------------------------------------------
// They run as frames: a native frame's arguments sit on vs right after the native itself (vs[k.base]),
// its state goes after them.

/// Push the frame of the native at vs[b] (its arguments follow it) and run its first step.
pub fn start(b: usize, e: *Env) E!Go {
    const k = frame(.native, &.{}, e);
    k.base = b;
    return step(k, null);
}

/// Resume a native frame with the value of its callback (null: first step).
pub fn step(k: *Frame, v: ?V) E!Go {
    const n = vs.items[k.base].asFn();
    return n.f.step(n, k, v);
}

/// The frame's arguments, padded with nil or cut to exactly n (so state can follow them).
pub fn frameArgs(k: *Frame, n: usize) []V {
    const end = k.base + 1 + n;
    while (vs.items.len < end) gc.push(V, &vs, .nil);
    vs.items.len = end;
    return vs.items[k.base + 1 ..];
}

/// Pop the frame and hand v to the next one.
pub fn finish(k: *Frame, v: V) Go {
    vs.items.len = k.base;
    ks.items.len -= 1;
    return .{ .ret = v };
}

/// Call f with xs (which must not live on vs); its value comes back to this frame.
pub fn callback(f: V, xs: []const V) Go {
    const b = vs.items.len;
    gc.push(V, &vs, f);
    vs.appendSlice(gpa, xs) catch gc.oom();
    return .{ .apply = b };
}

/// Replace the frame by a call of f with pre, then (if keep) the frame's arguments: f runs in tail position.
pub fn tail(k: *Frame, f: V, pre: []const V, keep: bool) Go {
    const b = k.base;
    if (!keep) vs.items.len = b + 1;
    vs.items[b] = f;
    vs.insertSlice(gpa, b + 1, pre) catch gc.oom();
    ks.items.len -= 1;
    return .{ .apply = b };
}

/// (try thunk handler) calls thunk; after an error, `recover` resumes the frame with k.i = 1 and the error value.
fn tryRun(_: *Fn, k: *Frame, v: ?V) E!Go {
    const a = frameArgs(k, 2);
    const r = v orelse return callback(a[0], &.{});
    return if (k.i == 1) tail(k, a[1], &.{r}, false) else finish(k, r);
}

/// After an error: drop the frames above the innermost try frame at or above base and resume it, if there is one.
pub fn recover(base: usize) ?Go {
    var j = ks.items.len;
    while (j > base) {
        j -= 1;
        const k = &ks.items[j];
        if (k.kind != .native or vs.items[k.base].asFn().f.step != &tryRun) continue;
        ks.items.len = j + 1;
        vs.items.len = k.base + 3; // try, thunk, handler
        k.i = 1;
        return .{ .ret = lang.errv };
    }
    return null;
}

// trampoline: nested calls while active return thunks, the outermost runs them in a loop
fn thunk(s: *Fn, k: *Frame, _: ?V) E!Go {
    return tail(k, s.d0, s.d1.asList().items(), false);
}

/// (trampoline f) is the function that runs f that way.
fn trampoline(_: *Fn, a: []const V) E!V {
    return V.fnOf(nf(.{ .step = trampRun }, arg(a, 0), .nil));
}

/// s.i - 1 is the index of the outermost run's frame. It is checked, not trusted: a frame dropped by an error
/// never finishes and so never clears it.
fn trampRun(s: *Fn, k: *Frame, v: ?V) E!Go {
    const frames = ks.items;
    const r = v orelse {
        const j = s.i -% 1;
        if (j < frames.len - 1 and frames[j].kind == .native and vs.items[frames[j].base].asFn() == s) {
            const a = vs.items[k.base + 1 ..];
            return finish(k, V.fnOf(nf(.{ .step = thunk }, s.d0, list(a, a.len))));
        }
        s.i = frames.len;
        vs.insertSlice(gpa, k.base + 1, &.{s.d0}) catch gc.oom(); // call s.d0 with the frame's arguments
        return .{ .apply = k.base + 1 };
    };
    if (r.is(.f) or r.is(.lam)) return callback(r, &.{});
    s.i = 0;
    return finish(k, r);
}

pub var root: *Env = undefined;

pub fn topLevel() *Env {
    const e: *Env = @ptrCast(@alignCast(gc.perm(@sizeOf(Env)))); // the root scope lives forever
    root = e;
    e.* = .{ .p = null, .vars = &.{}, .cap = 0 };
    set(e, "nil", .nil);
    set(e, "#t", V.boolean(true));
    set(e, "#f", V.boolean(false));
    set(e, "ESC", str("\x1b", .{}));
    prims.install(e);
    set(e, "trampoline", V.fnOf(nf(.{ .plain = trampoline }, .nil, .nil)));
    set(e, "try", V.fnOf(nf(.{ .step = tryRun }, .nil, .nil)));
    return e;
}

// compiler support
// ----------------------------------------------------------------
var interned: std.StringHashMapUnmanaged(*Sym) = .empty;

pub fn make(comptime T: type, n: usize) []T {
    return @as([*]T, @ptrCast(@alignCast(gc.perm(n * @sizeOf(T)))))[0..n];
}

pub fn stub(v: V) *Node {
    const n = &make(Node, 1)[0];
    n.* = .{ .ast = pin(v) };
    return n;
}

/// n nodes for the items of a, nil for missing ones.
pub fn kids(a: []const V, n: usize) []const *Node {
    const c = make(*Node, n);
    for (c, 0..) |*x, i| x.* = stub(arg(a, i));
    return c;
}

pub fn intern(v: V) *Sym { // equal names are the same symbol, so scopes compare keys by address
    const name = std.mem.span(if (v.is(.s)) v.asStr() else str("{f}", .{v}).asStr());
    const entry = interned.getOrPut(std.heap.c_allocator, name) catch gc.oom();
    if (!entry.found_existing) { // the table's key is the symbol's own name
        entry.value_ptr.* = &make(Sym, 1)[0];
        entry.value_ptr.*.* = .{ .key = mkstr(name, true) };
        entry.key_ptr.* = std.mem.span(entry.value_ptr.*.key);
    }
    return entry.value_ptr.*;
}

/// The call c of a, as a Prim node if its head is a global bound to a primitive that `fast` knows.
pub fn special(a: []const V, c: []const *Node) Code {
    if (a.len >= 3 and a[0].is(.s) and items(a[a.len - 1]).len > 0 and items(a[a.len - 1])[0].is(.s) and streq(items(a[a.len - 1])[0].asStr(), "lambda")) {
        const sym = intern(a[0]);
        const g = if (sym.local) null else slot(root, sym.key, false);
        if (g) |slotp| if (slotp.* == each_v or slotp.* == map_v) {
            c[c.len - 1].guard = &make(Guard, 1)[0];
            c[c.len - 1].guard.?.* = .{ .sym = sym, .g = slotp, .f = pin(slotp.*) };
        };
    }
    if ((a.len == 2 or a.len == 3) and a[0].is(.s)) {
        const sym = intern(a[0]);
        const g = if (sym.local) null else slot(root, sym.key, false);
        if (g) |slotp| if (prims.primOp(slotp.*)) |op| if (a.len == 2 and prims.unary(op) or a.len == 3 and !prims.unary(op)) {
            const p = &make(Prim, 1)[0];
            sym.inlined = true;
            p.* = .{ .op = op, .sym = sym, .g = slotp, .f = pin(slotp.*), .c = c };
            return .{ .prim = p };
        };
    }
    return .{ .call = c };
}
