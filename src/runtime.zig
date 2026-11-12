const std = @import("std");
const gc = @import("gc.zig");
const lang = @import("lang.zig");

// Values, iterative printing, and reference-counted constructors.

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

    /// Print iteratively: nested lists can't overflow the native stack.
    pub fn format(root: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var todo: std.ArrayList(?V) = .empty; // null: a list's closing parenthesis
        defer todo.deinit(gpa);
        gc.push(?V, &todo, root);
        while (todo.pop()) |item| {
            if (item) |v| switch (v) {
                .nil => try w.writeAll("nil"),
                .b => |b| try w.writeAll(if (b) "#t" else "#f"),
                .n => |n| if (n == @trunc(n) and @abs(n) < 1e18) try w.print("{d}", .{@as(i64, @intFromFloat(n))}) else try w.print("{d}", .{n}),
                .s => |s| try w.writeAll(std.mem.span(s)),
                .lit => |s| try w.print("\"{s}\"", .{s}),
                .l => |l| {
                    try w.writeByte('(');
                    gc.push(?V, &todo, null);
                    var it = std.mem.reverseIterator(l.a);
                    while (it.next()) |x| gc.push(?V, &todo, x);
                    continue;
                },
                .f, .lam => try w.writeAll("<function>"),
            } else try w.writeByte(')');
            if (todo.getLastOrNull()) |next| if (next != null) try w.writeByte(' '); // more items of the same list
        }
    }
};
pub const Lst = struct { a: []V }; // items are stored inline, right after the struct
pub const Fn = struct { f: *const fn (*Fn, []const V) E!V, d0: V, d1: V, i: usize = 0 }; // native fn + captured data
pub const Lam = struct { params: V, body: V, env: *Env };
pub const Env = struct { p: ?*Env, vars: []Var, cap: usize }; // vars are stored inline until they outgrow cap; the root scope uses the global table
pub const Var = struct { k: [*:0]const u8, v: V };

const gpa = std.heap.c_allocator;

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

fn mkstr(s: []const u8, perm: bool) [*:0]u8 {
    const t: [*]u8 = @ptrCast(if (perm) gc.perm(s.len + 1) else gc.alloc(s.len + 1, .str));
    @memcpy(t[0..s.len], s); // calloc: already 0-terminated
    return @ptrCast(t);
}

/// A runtime string built with std.fmt.
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

pub fn nf(f: *const fn (*Fn, []const V) E!V, d0: V, d1: V) *Fn {
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

// ---------------------------------------------------------------- parser
var src: []const u8 = "";
var pos: usize = 0;

fn peek() u8 {
    return if (pos < src.len) src[pos] else 0;
}

const space = " \t\n\r";

fn skip() void {
    while (true) {
        pos = std.mem.indexOfNonePos(u8, src, pos, space) orelse src.len;
        if (peek() != ';') return;
        pos = std.mem.indexOfAnyPos(u8, src, pos, "\n\x00") orelse src.len;
    }
}

fn atom() V { // symbols and literals are permanent; a 0 byte ends the source
    const lit = peek() == '"';
    const s = pos + @intFromBool(lit);
    pos = std.mem.indexOfAnyPos(u8, src, s, if (lit) "\"\x00" else space ++ "\x00()';\"") orelse src.len;
    const t = src[s..pos];
    if (lit and peek() == '"') pos += 1;
    if (lit) return .{ .lit = mkstr(t, true) };
    if (std.mem.indexOfAny(u8, t, "0123456789") != null) if (std.fmt.parseFloat(f64, t)) |d| return .{ .n = d } else |_| {};
    return .{ .s = mkstr(t, true) };
}

/// Iterative: `open` holds where each unfinished list starts in `done` (null: a pending quote).
pub fn parse(text: []const u8) E!V {
    src = text;
    pos = 0;
    var done: std.ArrayList(V) = .empty;
    defer done.deinit(gpa);
    var open: std.ArrayList(?usize) = .empty;
    defer open.deinit(gpa);
    while (open.items.len > 0 or done.items.len == 0) {
        skip();
        var d: V = switch (peek()) {
            0 => return fail(str("ToyLisp: Syntax error, unbalanced expression", .{})),
            '(', '\'' => |c| {
                pos += 1;
                gc.push(?usize, &open, if (c == '(') done.items.len else null);
                continue;
            },
            ')' => blk: {
                pos += 1;
                if (open.items.len == 0 or open.getLast() == null) return fail(str("ToyLisp: Syntax error, unexpected closing parenthesis", .{}));
                const xs = done.items[open.pop().?.?..];
                done.items.len -= xs.len;
                break :blk list(xs, xs.len);
            },
            else => atom(),
        };
        while (open.items.len > 0 and open.getLast() == null) : (_ = open.pop()) d = list(&.{ .{ .s = mkstr("quote", true) }, d }, 2);
        gc.push(V, &done, d);
    }
    skip();
    if (peek() != 0) return fail(str("ToyLisp: Syntax error, unexpected closing parenthesis", .{}));
    return done.items[0];
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

pub fn name(v: V) [*:0]const u8 {
    return if (v == .s) v.s else str("{f}", .{v}).s;
}

/// The slot of k in the nearest scope that has it.
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
const Op = enum { @"+", @"-", @"*", @"/", @">", @"<", @">=", @"<=", @"&&", @"||", @"eq?", car, cdr, len, cons, list, @"error", @"try", trampoline };

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
        .trampoline => return .{ .f = nf(trampRun, x, .nil) },
        .@"eq?" => return .{ .b = for (a) |y| (if (!eq(y, x)) break false) else true },
        .cons => {
            const r = list(&.{x}, l.len + 1);
            for (l, r.l.a[1..]) |y, *z| z.* = rv(y);
            return r;
        },
        .@"try" => return lang.call(x, &.{}) catch lang.call(arg(a, 1), &.{lang.errv}),
        else => unreachable,
    }
}

// trampoline: nested calls while active return thunks, the outermost runs them
fn thunk(s: *Fn, _: []const V) E!V {
    return lang.call(s.d0, s.d1.l.a);
}

fn trampRun(s: *Fn, a: []const V) E!V {
    if (s.i != 0) return .{ .f = nf(thunk, s.d0, list(a, a.len)) };
    var m = gc.mark();
    s.i = 1;
    defer s.i = 0; // also when the body raises an error
    var r = try lang.call(s.d0, a);
    while (r == .f or r == .lam) {
        r = try lang.call(r, &.{});
        m = gc.resweep(m, r, null);
    }
    return r;
}

pub fn topLevel() *Env {
    const e: *Env = @ptrCast(@alignCast(gc.perm(@sizeOf(Env)))); // the root scope lives forever
    e.* = .{ .p = null, .vars = &.{}, .cap = 0 };
    set(e, "nil", .nil);
    set(e, "#t", .{ .b = true });
    set(e, "#f", .{ .b = false });
    for (std.enums.values(Op)) |op| set(e, @tagName(op), .{ .f = nf(prim, .{ .n = @floatFromInt(@backingInt(op)) }, .nil) }); // d0: the op
    return e;
}
