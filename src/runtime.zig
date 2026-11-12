const std = @import("std");
const gc = @import("gc.zig");
const lang = @import("lang.zig");

pub const E = error{Lisp}; // the error value itself is in `errv`
pub const V = union(enum) { // s: symbol or runtime string, lit: string literal from source
    nil,
    b: bool,
    n: f64,
    s: [*:0]const u8,
    lit: [*:0]const u8,
    l: *Lst,
    f: *Fn,
    lam: *Lam,

    pub const format = @import("stdlib_native.zig").format;
};
pub const Lst = struct { a: []V }; // items are stored inline, right after the struct
pub const Fn = struct { f: Native, d0: V, d1: V, i: usize = 0 };
/// plain: computes its value directly. step: calls back into Lisp, so it runs as a frame of the machine: it is
/// invoked with null first, then with each callback's value, and says what the machine does next.
pub const Native = union(enum) { plain: *const fn (*Fn, []const V) E!V, step: *const fn (*Fn, *K, ?V) E!Go };
pub const Lam = struct { params: V, body: V, env: *Env };
pub const Env = struct { p: ?*Env, vars: []Var, cap: usize }; // vars are stored inline until they outgrow cap; the root scope uses the global table
pub const Var = struct { k: [*:0]const u8, v: V };

const gpa = std.heap.c_allocator;

// The machine's state: pending work lives in heap frames, so nothing grows the native stack.
pub const Form = enum { quote, lambda, @"if", begin, define, @"set!", apply, native }; // apply: anything else
pub const K = struct { kind: Form, i: usize, base: usize, mark: usize, l: []V, e: *Env };
pub const Go = union(enum) { eval: V, ret: V, apply: usize }; // apply: the function at vs[apply], then its arguments
pub var ks: std.ArrayList(K) = .empty;
pub var vs: std.ArrayList(V) = .empty; // function + arguments being collected, native frames' state

pub fn ptr(v: V) ?*anyopaque {
    return switch (v) {
        .nil, .b, .n => null,
        .s, .lit => |s| @ptrCast(@constCast(s)),
        inline else => |p| p,
    };
}

/// A heap reference to v is being stored.
pub fn rv(v: V) V {
    gc.ret(ptr(v));
    return v;
}

pub fn arg(a: []const V, i: usize) V {
    return if (i < a.len) a[i] else .nil;
}

pub fn items(v: V) []V {
    return if (v == .l) v.l.a else &.{};
}

pub fn mkstr(s: []const u8, perm: bool) [*:0]u8 {
    const t: [*]u8 = @ptrCast(if (perm) gc.perm(s.len + 1) else gc.alloc(s.len + 1, .str));
    @memcpy(t[0..s.len], s); // calloc: already 0-terminated
    return @ptrCast(t);
}

pub fn str(comptime f: []const u8, args: anytype) V {
    const m = std.fmt.allocPrint(gpa, f, args) catch gc.oom();
    defer gpa.free(m);
    return .{ .s = mkstr(m, false) };
}

pub fn fail(e: V) E {
    lang.errv = e;
    return error.Lisp;
}

/// A list of n items: a, then nils.
pub fn list(a: []const V, n: usize) V {
    const l = gc.new(Lst, n * @sizeOf(V), .list, undefined);
    l.a = gc.after(V, l)[0..n];
    for (l.a, 0..) |*x, i| x.* = rv(arg(a, i));
    return .{ .l = l };
}

pub fn nf(f: Native, d0: V, d1: V) *Fn {
    return gc.new(Fn, 0, .func, .{ .f = f, .d0 = rv(d0), .d1 = rv(d1) });
}

pub fn truthy(v: V) bool {
    return switch (v) {
        .nil => false,
        .b => |b| b,
        .n => |n| n != 0 and n == n,
        .s => |s| s[0] != 0,
        else => true,
    };
}

fn isNil(v: V) bool {
    return v == .nil or (v == .l and v.l.a.len == 0);
}

fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

fn eq(a: V, b: V) bool {
    if (isNil(a) or isNil(b)) return isNil(a) and isNil(b);
    if ((a == .s and b == .s) or (a == .lit and b == .lit)) return streq(@ptrCast(ptr(a)), @ptrCast(ptr(b)));
    return std.meta.eql(a, b);
}

pub fn num(v: V) f64 {
    return switch (v) {
        .n => |n| n,
        .b => |b| @floatFromInt(@intFromBool(b)),
        .nil => 0,
        else => std.math.nan(f64),
    };
}

// ---------------------------------------------------------------- scopes
pub var macros: std.ArrayList(*V) = .empty; // root slots of the macro/* functions
var gk: [1 << 13]?[*:0]const u8 = @splat(null); // globals: open addressing, FNV-1a
var gv: [1 << 13]V = @splat(.nil);

fn slot(e: *Env, k: [*:0]const u8, create: bool) ?*V {
    if (e.p == null) {
        var i: usize = std.hash.Fnv1a_32.hash(std.mem.span(k)) & (gk.len - 1);
        while (gk[i]) |key| : (i = (i + 1) & (gk.len - 1)) if (streq(key, k)) return &gv[i];
        if (create) gk[i] = k;
        return if (create) &gv[i] else null;
    }
    var it = std.mem.reverseIterator(e.vars); // the latest binding of a name wins
    while (it.nextPtr()) |x| if (x.k == k or streq(x.k, k)) return &x.v;
    if (!create) return null;
    if (e.vars.len == e.cap) {
        const more = gpa.alloc(Var, e.cap * 2) catch gc.oom();
        @memcpy(more[0..e.cap], e.vars);
        if (e.vars.ptr != gc.after(Var, e)) gpa.free(e.vars);
        e.vars.ptr, e.cap = .{ more.ptr, more.len };
    }
    e.vars.len += 1;
    e.vars[e.vars.len - 1] = .{ .k = k, .v = .nil };
    return &e.vars[e.vars.len - 1].v;
}

fn name(v: V) [*:0]const u8 {
    return if (v == .s) v.s else str("{f}", .{v}).s;
}

/// (define name v) or (set! name v), a being the form.
pub fn assign(define: bool, a: []const V, e: *Env, v: V) E!void {
    if (a.len < 2) return fail(str("ToyLisp: {s} needs a name", .{if (define) "define" else "set!"}));
    const s = name(a[1]);
    if (define) set(e, s, v) else if (lookup(e, s)) |p| {
        gc.rel(ptr(p.*));
        p.* = rv(v);
    }
}

pub fn lookup(env: *Env, k: [*:0]const u8) ?*V {
    var e: ?*Env = env;
    while (e) |s| : (e = s.p) if (slot(s, k, false)) |v| return v;
    return null;
}

/// Root keys are copied to permanent memory; scope keys are counted references.
pub fn set(e: *Env, key: [*:0]const u8, v: V) void {
    const s = slot(e, key, false) orelse blk: {
        const s = slot(e, if (e.p != null) rv(.{ .s = key }).s else mkstr(std.mem.span(key), true), true).?;
        if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) gc.push(*V, &macros, s);
        break :blk s;
    };
    gc.rel(ptr(s.*));
    s.* = rv(v);
}

pub fn lambda(a: []const V, e: *Env) V {
    gc.ret(e);
    return .{ .lam = gc.new(Lam, 0, .lam, .{ .params = rv(arg(a, 1)), .body = rv(arg(a, 2)), .env = e }) };
}

pub fn bind(f: *Lam, a: []const V) *Env {
    const ps = items(f.params);
    const cap = @max(ps.len, 4);
    const e = gc.new(Env, cap * @sizeOf(Var), .env, .{ .p = f.env, .vars = undefined, .cap = cap });
    e.vars = gc.after(Var, e)[0..ps.len];
    gc.ret(f.env);
    for (ps, e.vars, 0..) |p, *x, i| x.* = .{ .k = rv(.{ .s = name(p) }).s, .v = rv(arg(a, i)) };
    return e;
}

// ---------------------------------------------------------------- primitives
const Op = enum { @"+", @"-", @"*", @"/", @">", @"<", @">=", @"<=", @"&&", @"||", @"eq?", car, cdr, len, cons, list, @"error", trampoline };

fn binop(op: Op, x: V, y: V) V {
    const a = num(x);
    const b = num(y);
    return switch (op) {
        .@"+" => if (x == .s or x == .lit or y == .s or y == .lit) str("{f}{f}", .{ x, y }) else .{ .n = a + b },
        .@"-" => .{ .n = a - b },
        .@"*" => .{ .n = a * b },
        .@"/" => .{ .n = a / b },
        .@">" => .{ .b = a > b },
        .@"<" => .{ .b = a < b },
        .@">=" => .{ .b = a >= b },
        .@"<=" => .{ .b = a <= b },
        .@"&&" => if (truthy(x)) y else x,
        else => if (truthy(x)) x else y,
    };
}

fn prim(s: *Fn, a: []const V) E!V {
    const op: Op = @fromBackingInt(@intFromFloat(s.d0.n));
    const x = arg(a, 0);
    if (@backingInt(op) <= @backingInt(Op.@"||")) { // arithmetic, comparison, && and ||: fold left
        var r = x;
        for (a[@min(1, a.len)..]) |y| r = binop(op, r, y);
        return r;
    }
    const l = items(if (op == .cons) arg(a, 1) else x);
    switch (op) {
        .car => return arg(l, 0),
        .cdr => return list(l[@min(1, l.len)..], l.len -| 1),
        .len => return .{ .n = @floatFromInt(l.len) },
        .list => return list(a, a.len),
        .@"error" => return fail(x),
        .trampoline => return .{ .f = nf(.{ .step = trampRun }, x, .nil) },
        .@"eq?" => return .{ .b = for (a) |y| (if (!eq(y, x)) break false) else true },
        .cons => {
            const r = list(&.{x}, l.len + 1);
            for (l, r.l.a[1..]) |y, *z| z.* = rv(y);
            return r;
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- natives that call back into Lisp
// They run as frames: a native frame's arguments sit on vs right after the native itself (vs[k.base]),
// its state goes after them. Values held only there are not counted (see gc.zig).

/// Push the frame of the native at vs[b] (its arguments follow it) and run its first step.
pub fn start(b: usize, e: *Env) E!Go {
    gc.push(K, &ks, .{ .kind = .native, .i = 0, .base = b, .mark = gc.mark(), .l = &.{}, .e = e });
    return step(&ks.items[ks.items.len - 1], null);
}

/// Resume a native frame with the value of its callback (null: first step).
pub fn step(k: *K, v: ?V) E!Go {
    const n = vs.items[k.base].f;
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
pub fn callback(k: *K, f: V, xs: []const V) Go {
    const b = vs.items.len;
    gc.push(V, &vs, f);
    vs.appendSlice(gpa, xs) catch gc.oom();
    k.mark = gc.mark(); // the callback's region: its value is swept against it, like an argument's
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
        if (k.kind != .native or vs.items[k.base].f.f.step != &tryRun) continue;
        ks.items.len = j + 1;
        vs.items.len = k.base + 3; // try, thunk, handler
        k.i = 1;
        return .{ .ret = lang.errv };
    }
    return null;
}

// trampoline: nested calls while active return thunks, the outermost runs them in a loop
fn thunk(s: *Fn, k: *K, _: ?V) E!Go {
    return tail(k, s.d0, s.d1.l.a, false);
}

/// s.i - 1 is the index of the outermost run's frame. It is checked, not trusted: a frame dropped by an error
/// never finishes and so never clears it.
fn trampRun(s: *Fn, k: *K, v: ?V) E!Go {
    const frames = ks.items;
    const r = v orelse {
        const j = s.i -% 1;
        if (j < frames.len - 1 and frames[j].kind == .native and vs.items[frames[j].base].f == s) {
            const a = vs.items[k.base + 1 ..];
            return finish(k, .{ .f = nf(.{ .step = thunk }, s.d0, list(a, a.len)) });
        }
        s.i = frames.len;
        k.i = gc.mark(); // the loop's region
        vs.insertSlice(gpa, k.base + 1, &.{s.d0}) catch gc.oom(); // call s.d0 with the frame's arguments
        k.mark = gc.mark();
        return .{ .apply = k.base + 1 };
    };
    k.i = gc.resweep(k.i, r, null);
    if (r == .f or r == .lam) return callback(k, r, &.{});
    s.i = 0;
    return finish(k, r);
}

pub fn topLevel() *Env {
    const e: *Env = @ptrCast(@alignCast(gc.perm(@sizeOf(Env)))); // the root scope lives forever
    e.* = .{ .p = null, .vars = &.{}, .cap = 0 };
    set(e, "nil", .nil);
    set(e, "#t", .{ .b = true });
    set(e, "#f", .{ .b = false });
    set(e, "ESC", str("\x1b", .{}));
    for (std.enums.values(Op)) |op| set(e, @tagName(op), .{ .f = nf(.{ .plain = prim }, .{ .n = @floatFromInt(@backingInt(op)) }, .nil) }); // d0: the op
    set(e, "try", .{ .f = nf(.{ .step = tryRun }, .nil, .nil) });
    return e;
}
