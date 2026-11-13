const std = @import("std");
const gc = @import("gc.zig");
const lang = @import("lang.zig");

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
pub const Fn = struct { f: Native, d0: V, d1: V, i: usize = 0 };
/// plain: computes its value directly. step: calls back into Lisp, so it runs as a frame of the machine: it is
/// invoked with null first, then with each callback's value, and says what the machine does next.
pub const Native = union(enum) { plain: *const fn (*Fn, []const V) E!V, step: *const fn (*Fn, *K, ?V) E!Go };
pub const Lam = struct { proto: *Proto, env: *Env };
pub const Env = struct { p: ?*Env, vars: []Var, cap: usize, proto: ?*Proto = null, esc: bool = false }; // vars are stored inline until they outgrow cap; the root scope uses the global table
pub const Var = struct { k: Key, v: V };

// Compiled code (see the compiler in lang.zig). Nodes and their arrays live forever, so frames and closures can keep pointing at them.
pub const Key = [*:0]const u8; // a symbol, interned: equal names are the same pointer
pub const Sym = struct { key: Key, local: bool = false, prim: bool = false }; // prim: the head of a Prim node, so tier-2 code inlines it (rebinding it bumps epoch) // local: some scope binds this name (a parameter, or a define inside a function)
/// A call of a primitive on two operands, compiled as such while its name is global and still bound to that primitive: the evaluator
/// computes it in place when both operands are constants or variables holding numbers (or a list and an index), else it is the call c.
pub const Prim = struct { op: Op, sym: *Sym, g: *V, f: V, c: []const *Node, slow: bool = false }; // slow: an operand is a call, so it is never computed in place
pub const Ref = struct { sym: *Sym, g: ?*V = null }; // g: the global slot, once found
pub const Def = struct { sym: ?*Sym, g: ?*V = null, val: *Node, define: bool }; // define or set!
pub const Proto = struct { params: []const Key, body: *Node, cap: usize = 0, rest: bool = false, guard: ?*Guard = null, code: ?*Bytecode = null, tried: bool = false }; // code: the tier-2 form of the body (vm.zig) // cap: room for the scope of a call, grown by defines
pub const Code = union(enum) { raw, val: V, ref: Ref, @"if": []const *Node, begin: []const *Node, def: *Def, lambda: *Proto, prim: *Prim, @"&&": []const *Node, @"||": []const *Node, call: []const *Node };
/// Tier 2 (vm.zig): a function body as a stack bytecode over fixed scope slots (keys: parameters, then defines).
pub const Opcode = enum(u8) { konst, local, outer, setlocal, setouter, pop, jmp, jmpf, andj, orj, lambda, add, sub, mul, lt, gt, le, ge, eq, at, prim1, prim2, call, tailcall, ret };
pub const Ins = struct { op: Opcode, a: u16 = 0, b: u32 = 0 };
pub const Bytecode = struct { ins: []const Ins, consts: []const V, refs: []const *Ref, prims: []const *Prim, defs: []const *Def, protos: []const *Proto, keys: []const Key, stamp: u32 };
/// The lambda that is the last operand of a call of each or map (while that name is still global and the native): the native only
/// calls it, so creating it does not capture its scope (lambda below).
pub const Guard = struct { sym: *Sym, g: *V, f: V };
pub const Node = struct { ast: V, src: V = .nil, stamp: u32 = 0, code: Code = .raw, guard: ?*Guard = null }; // src: the (expanded) form that code was built from

pub const gpa = std.heap.c_allocator;

// The machine's state: pending work lives in heap frames, so nothing grows the native stack.
pub const Form = enum { quote, lambda, @"if", begin, define, @"set!", @"&&", @"||", apply }; // apply: anything else
pub const Kind = enum { @"if", @"&&", @"||", begin, def, call, native, vm };
pub const K = struct { kind: Kind, i: usize, base: usize, c: []const *Node, d: *Def = undefined, e: *Env, code: *Bytecode = undefined }; // vm frames: i is the pc to resume at
/// A running evaluator loop: its scope is a root for the collector.
pub const M = struct { e: *Env, base: usize };
pub var machines: std.ArrayList(*M) = .empty;
/// Values that permanent compiled nodes point to (the AST and its expansions) stay alive for good.
pub var pins: std.ArrayList(V) = .empty;

pub fn pin(v: V) V {
    gc.push(V, &pins, v);
    return v;
}
pub const Go = union(enum) { eval: *Node, ret: V, vm: struct { code: *Bytecode, pc: usize }, apply: usize, args: struct { c: []const *Node, i: usize, b: usize } }; // apply: the function at vs[apply], then its arguments; args: collecting them from c[i] on, they start at vs[b]

/// Push the value of c[i], an item of a call: the function first, which must exist.
pub inline fn operand(c: []const *Node, i: usize, v: V) E!void {
    if (i == 0 and v == V.nil) return fail(str("TinyLisp: Function {f} is not defined", .{c[0].ast}));
    gc.push(V, &vs, v);
}

pub fn frame(kind: Kind, c: []const *Node, e: *Env) *K {
    gc.push(K, &ks, .{ .kind = kind, .i = 0, .base = vs.items.len, .c = c, .e = e });
    return &ks.items[ks.items.len - 1];
}
pub var ks: std.ArrayList(K) = .empty;
pub var vs: std.ArrayList(V) = .empty; // function + arguments being collected, native frames' state

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

pub var epoch: u32 = 0; // bumped when a macro/* changes: code compiled before it is compiled again

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
        if (sym.prim and !sym.local and e.p != null) epoch +%= 1;
        sym.local = sym.local or e.p != null;
        set(e, sym.key, v);
    } else if (find(e, sym, &d.g)) |p| {
        if (p.*.is(.f)) epoch +%= 1;
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
    if (e.p == null and s.*.is(.f)) epoch +%= 1; // a native (maybe a primitive that tier-2 code inlines) is replaced
    s.* = v;
    if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) epoch +%= 1;
}

pub fn lambda(p: *Proto, e: *Env) V {
    if (p.guard) |d| if (!d.sym.local and d.g.* == d.f) return V.lamOf(gc.new(Lam, 0, .lam, .{ .proto = p, .env = e })); // a loop body: dead once the loop is over
    var s: ?*Env = e; // a closure holds the scope and, through it, the enclosing ones: none can be recycled when its call ends
    while (s) |x| : (s = x.p) x.esc = true;
    return V.lamOf(gc.new(Lam, 0, .lam, .{ .proto = p, .env = e }));
}

// Most scopes die when their call ends: a call's scope is recycled then, unless a closure captured it. Recycled scopes wait on
// a free list (linked through `p`); the collector forgets the list, so whatever it holds is simply collected.
const env_cap = 4;
pub var env_pool: ?*Env = null;

pub fn bind(f: *Lam, a: []const V) *Env {
    const ps = f.proto.params;
    const n = if (f.proto.code) |c| c.keys.len else ps.len; // tier 2: the defines of the body have their slots from the start
    const cap = @max(f.proto.cap, n, env_cap);
    const e = if (cap == env_cap and env_pool != null) blk: {
        const e = env_pool.?;
        env_pool = e.p;
        break :blk e;
    } else gc.new(Env, cap * @sizeOf(Var), .env, undefined);
    e.* = .{ .p = f.env, .vars = gc.after(Var, e)[0..n], .cap = cap, .proto = f.proto, .esc = cap != env_cap };
    const fixed = ps.len - @intFromBool(f.proto.rest); // a last parameter after & takes the extra arguments as a list
    for (ps[0..fixed], e.vars[0..fixed], 0..) |k, *x, i| x.* = .{ .k = k, .v = arg(a, i) };
    if (f.proto.rest) e.vars[fixed] = .{ .k = ps[fixed], .v = list(if (a.len > fixed) a[fixed..] else &.{}, a.len -| fixed) };
    if (f.proto.code) |c| for (c.keys[ps.len..], e.vars[ps.len..]) |k, *x| {
        x.* = .{ .k = k, .v = .nil };
    };
    return e;
}

/// The call that ran in e is over (nothing but a closure could still use it).
pub fn release(e: *Env) void {
    if (e.esc or e.p == null or e.cap != env_cap or e.vars.ptr != gc.after(Var, e)) return;
    e.esc = true; // never twice
    e.p = env_pool;
    env_pool = e;
}

// primitives
// ----------------------------------------------------------------
pub const Op = enum { @"+", @"-", @"*", @"/", mod, @">", @"<", @">=", @"<=", @"&&", @"||", @"eq?", car, cdr, len, cons, list, @"error", at, trampoline, @"vset!", not, min, max, exp, log, sqrt, cos, floor, abs };

fn binop(op: Op, x: V, y: V) V {
    const a = num(x);
    const b = num(y);
    return switch (op) {
        .@"+" => if (x.is(.s) or x.is(.lit) or y.is(.s) or y.is(.lit)) str("{f}{f}", .{ x, y }) else V.num(a + b),
        .@"-" => V.num(a - b),
        .@"*" => V.num(a * b),
        .@"/" => V.num(a / b),
        .mod => V.num(a - b * @floor(a / b)),
        .@">" => V.boolean(a > b),
        .@"<" => V.boolean(a < b),
        .@">=" => V.boolean(a >= b),
        .@"<=" => V.boolean(a <= b),
        .@"&&" => if (truthy(x)) y else x,
        else => if (truthy(x)) x else y,
    };
}

/// One native per op, so each is specialised at compile time.
fn primFor(comptime op: Op) *const fn (*Fn, []const V) E!V {
    return struct {
        fn f(_: *Fn, a: []const V) E!V {
            return prim(op, a);
        }
    }.f;
}

inline fn prim(comptime op: Op, a: []const V) E!V {
    const x = arg(a, 0);
    if (@backingInt(op) <= @backingInt(Op.@"||")) { // arithmetic, comparison, && and ||: fold left
        if (a.len == 2 and a[0].isNum() and a[1].isNum()) {
            const p = a[0].asNum();
            const q = a[1].asNum();
            switch (op) {
                .@"+" => return V.num(p + q),
                .@"-" => return V.num(p - q),
                .@"*" => return V.num(p * q),
                .@"/" => return V.num(p / q),
                .mod => return V.num(p - q * @floor(p / q)),
                .@">" => return V.boolean(p > q),
                .@"<" => return V.boolean(p < q),
                .@">=" => return V.boolean(p >= q),
                .@"<=" => return V.boolean(p <= q),
                else => {},
            }
        }
        var r = x;
        for (a[@min(1, a.len)..]) |y| r = binop(op, r, y);
        return r;
    }
    if (@backingInt(op) >= @backingInt(Op.exp)) { // math: one number in, one number out
        const n = num(x);
        return V.num(switch (op) {
            .exp => @exp(n),
            .log => @log(n),
            .sqrt => @sqrt(n),
            .cos => @cos(n),
            .abs => @abs(n),
            else => @floor(n),
        });
    }
    if (op == .not) return V.boolean(!truthy(x));
    if (op == .min or op == .max) { // several numbers or one list, like Python's
        const l = if (a.len == 1 and x.is(.l)) items(x) else a;
        if (l.len == 0) return fail(str("TinyLisp: {s} of nothing", .{@tagName(op)}));
        var r = l[0];
        for (l[1..]) |y| if (if (op == .min) num(y) < num(r) else num(y) > num(r)) {
            r = y;
        };
        return r;
    }
    const l = items(if (op == .cons) arg(a, 1) else x);
    switch (op) {
        .car => return arg(l, 0),
        .cdr => return list(l[@min(1, l.len)..], l.len -| 1),
        .len => return V.num(@floatFromInt(l.len)),
        .at => {
            const i = num(arg(a, 1));
            return if (i >= 0 and i < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(i)] else .nil;
        },
        .list => return list(a, a.len),
        .@"error" => return fail(x),
        .trampoline => return V.fnOf(nf(.{ .step = trampRun }, x, .nil)),
        .@"vset!" => { // (vset! list i v): store v at index i of the list itself (nothing needs a write barrier)
            const i = num(arg(a, 1));
            if (!(i >= 0 and i < @as(f64, @floatFromInt(l.len)))) return fail(str("TinyLisp: vset! index out of range", .{}));
            l[@intFromFloat(i)] = arg(a, 2);
            return arg(a, 2);
        },
        .@"eq?" => return V.boolean(for (a) |y| (if (!eq(y, x)) break false) else true),
        .cons => {
            const r = list(&.{x}, l.len + 1);
            for (l, r.asList().items()[1..]) |y, *z| z.* = y;
            return r;
        },
        else => unreachable,
    }
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
pub fn step(k: *K, v: ?V) E!Go {
    const n = vs.items[k.base].asFn();
    return n.f.step(n, k, v);
}

/// The frame's arguments, padded with nil or cut to exactly n (so state can follow them).
pub fn frameArgs(k: *K, n: usize) []V {
    const end = k.base + 1 + n;
    while (vs.items.len < end) gc.push(V, &vs, .nil);
    vs.items.len = end;
    return vs.items[k.base + 1 ..];
}

/// Pop the frame and hand v to the next one.
pub fn finish(k: *K, v: V) Go {
    vs.items.len = k.base;
    ks.items.len -= 1;
    return .{ .ret = v };
}

/// Call f with xs (which must not live on vs); its value comes back to this frame.
pub fn callback(_: *K, f: V, xs: []const V) Go {
    const b = vs.items.len;
    gc.push(V, &vs, f);
    vs.appendSlice(gpa, xs) catch gc.oom();
    return .{ .apply = b };
}

/// Replace the frame by a call of f with pre, then (if keep) the frame's arguments: f runs in tail position.
pub fn tail(k: *K, f: V, pre: []const V, keep: bool) Go {
    const b = k.base;
    if (!keep) vs.items.len = b + 1;
    vs.items[b] = f;
    vs.insertSlice(gpa, b + 1, pre) catch gc.oom();
    ks.items.len -= 1;
    return .{ .apply = b };
}

/// (try thunk handler) calls thunk; after an error, `recover` resumes the frame with k.i = 1 and the error value.
fn tryRun(_: *Fn, k: *K, v: ?V) E!Go {
    const a = frameArgs(k, 2);
    const r = v orelse return callback(k, a[0], &.{});
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
fn thunk(s: *Fn, k: *K, _: ?V) E!Go {
    return tail(k, s.d0, s.d1.asList().items(), false);
}

/// s.i - 1 is the index of the outermost run's frame. It is checked, not trusted: a frame dropped by an error
/// never finishes and so never clears it.
fn trampRun(s: *Fn, k: *K, v: ?V) E!Go {
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
    if (r.is(.f) or r.is(.lam)) return callback(k, r, &.{});
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
    inline for (comptime std.enums.values(Op)) |op| set(e, @tagName(op), V.fnOf(nf(.{ .plain = primFor(op) }, .nil, .nil)));
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
        if (g) |slotp| if (slotp.*.is(.f) and slotp.*.asFn().f == .step and (streq(sym.key, "each") or streq(sym.key, "map"))) {
            c[c.len - 1].guard = &make(Guard, 1)[0];
            c[c.len - 1].guard.?.* = .{ .sym = sym, .g = slotp, .f = pin(slotp.*) };
        };
    }
    if ((a.len == 2 or a.len == 3) and a[0].is(.s)) {
        const sym = intern(a[0]);
        const g = if (sym.local) null else slot(root, sym.key, false);
        if (g) |slotp| if (primOp(slotp.*)) |op| if (a.len == 2 and unary(op) or a.len == 3 and !unary(op)) {
            const p = &make(Prim, 1)[0];
            sym.prim = true;
            p.* = .{ .op = op, .sym = sym, .g = slotp, .f = pin(slotp.*), .c = c };
            return .{ .prim = p };
        };
    }
    return .{ .call = c };
}

fn primOp(v: V) ?Op {
    if (!v.is(.f) or v.asFn().f != .plain) return null;
    inline for (comptime std.enums.values(Op)) |op| {
        if (v.asFn().f.plain == primFor(op)) return switch (op) {
            .@"+", .@"-", .@"*", .@"/", .mod, .@">", .@"<", .@">=", .@"<=", .@"eq?", .at, .not, .abs, .floor, .sqrt, .exp, .log, .cos => op,
            else => null,
        };
    }
    return null;
}

fn unary(op: Op) bool {
    return switch (op) {
        .not, .abs, .floor, .sqrt, .exp, .log, .cos => true,
        else => false,
    };
}

/// The value of (op x) for a one-operand primitive, null if x is not a number (not: always).
pub fn fast1(op: Op, x: V) ?V {
    if (op == .not) return V.boolean(!truthy(x));
    if (!x.isNum()) return null;
    const p = x.asNum();
    return V.num(switch (op) {
        .abs => @abs(p),
        .floor => @floor(p),
        .sqrt => @sqrt(p),
        .exp => @exp(p),
        .log => @log(p),
        else => @cos(p),
    });
}

/// The value of (op x y) when it needs no allocation and no error, else null.
pub fn fast(op: Op, x: V, y: V) ?V {
    if (op == .@"eq?") return V.boolean(eq(x, y));
    if (!y.isNum()) return null;
    const q = y.asNum();
    if (op == .at) {
        if (!x.is(.l)) return null;
        const l = x.asList().items();
        return if (q >= 0 and q < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(q)] else null;
    }
    if (!x.isNum()) return null;
    const p = x.asNum();
    return switch (op) {
        .@"+" => V.num(p + q),
        .@"-" => V.num(p - q),
        .@"*" => V.num(p * q),
        .@"/" => V.num(p / q),
        .mod => V.num(p - q * @floor(p / q)),
        .@">" => V.boolean(p > q),
        .@"<" => V.boolean(p < q),
        .@">=" => V.boolean(p >= q),
        .@"<=" => V.boolean(p <= q),
        else => null,
    };
}
