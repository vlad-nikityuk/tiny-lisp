const std = @import("std");
const gc = @import("gc.zig");
const native = @import("stdlib_native.zig");

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

    pub fn format(v: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return pr(w, v);
    }
};
pub const Lst = struct { a: []V }; // items are stored inline, right after the struct
pub const Fn = struct { f: *const fn (*Fn, []const V) E!V, d0: V, d1: V, i: usize = 0 }; // native fn + captured data
pub const Lam = struct { params: V, body: V, env: *Env };
pub const Env = struct { p: ?*Env, n: usize, cap: usize, k: [*][*:0]const u8, v: [*]V }; // arrays inline until they grow

const gpa = std.heap.c_allocator;
pub var out: *std.Io.Writer = undefined;
var errv: V = .nil;
var in_macro = false;
var macros: [64][*:0]const u8 = undefined;
var nmacros: usize = 0;

pub fn ptr(v: V) ?*anyopaque {
    return switch (v) {
        .s, .lit => |s| @ptrCast(@constCast(s)),
        .l => |l| l,
        .f => |f| f,
        .lam => |l| l,
        else => null,
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
    @memcpy(t[0..s.len], s);
    t[s.len] = 0;
    return @ptrCast(t);
}

/// A runtime string built with std.fmt.
pub fn str(comptime f: []const u8, args: anytype) V {
    const m = std.fmt.allocPrint(gpa, f, args) catch gc.oom();
    defer gpa.free(m);
    return .{ .s = mkstr(m, false) };
}

fn fail(e: V) E {
    errv = e;
    return error.Lisp;
}

pub fn list(a: ?[]const V, n: usize) V {
    const l = gc.new(Lst, n * @sizeOf(V), .list);
    l.a = gc.after(V, l)[0..n];
    for (l.a, 0..) |*x, i| x.* = if (a) |from| rv(from[i]) else .nil;
    return .{ .l = l };
}

pub fn nf(f: *const fn (*Fn, []const V) E!V, d0: V, d1: V) *Fn {
    const r = gc.new(Fn, 0, .func);
    r.* = .{ .f = f, .d0 = rv(d0), .d1 = rv(d1) };
    return r;
}

fn truthy(v: V) bool {
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
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .b => |x| x == b.b,
        .n => |x| x == b.n,
        .s => |x| streq(x, b.s),
        .lit => |x| streq(x, b.lit),
        .l => |x| x == b.l,
        .f => |x| x == b.f,
        .lam => |x| x == b.lam,
        .nil => true,
    };
}

pub fn num(v: V) f64 {
    return switch (v) {
        .n => |n| n,
        .b => |b| @floatFromInt(@intFromBool(b)),
        .nil => 0,
        else => std.math.nan(f64),
    };
}

/// Print iteratively: nested lists can't overflow the native stack.
fn pr(w: *std.Io.Writer, root: V) std.Io.Writer.Error!void {
    var stack: std.ArrayList(struct { l: *Lst, i: usize }) = .empty;
    defer stack.deinit(gpa);
    var v = root;
    while (true) {
        switch (v) {
            .nil => try w.writeAll("nil"),
            .b => |b| try w.writeAll(if (b) "#t" else "#f"),
            .n => |n| if (n == @trunc(n) and @abs(n) < 1e18) try w.print("{d}", .{@as(i64, @intFromFloat(n))}) else try w.print("{d}", .{n}),
            .s => |s| try w.writeAll(std.mem.span(s)),
            .lit => |s| try w.print("\"{s}\"", .{s}),
            .l => |l| {
                stack.append(gpa, .{ .l = l, .i = 0 }) catch gc.oom();
                try w.writeByte('(');
            },
            .f, .lam => try w.writeAll("<function>"),
        }
        while (true) { // move to the next element, closing finished lists
            if (stack.items.len == 0) return;
            const top = &stack.items[stack.items.len - 1];
            if (top.i < top.l.a.len) {
                if (top.i > 0) try w.writeByte(' ');
                v = top.l.a[top.i];
                top.i += 1;
                break;
            }
            try w.writeByte(')');
            stack.items.len -= 1;
        }
    }
}

// ---------------------------------------------------------------- parser
var src: []const u8 = "";
var pos: usize = 0;

fn peek() u8 {
    return if (pos < src.len) src[pos] else 0;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skip() void {
    while (true) {
        while (isSpace(peek())) pos += 1;
        if (peek() != ';') return;
        while (peek() != 0 and peek() != '\n') pos += 1;
    }
}

fn atom() V { // symbols and literals are permanent
    if (peek() == '"') {
        pos += 1;
        const s = pos;
        while (peek() != 0 and peek() != '"') pos += 1;
        const v: V = .{ .lit = mkstr(src[s..pos], true) };
        if (peek() != 0) pos += 1;
        return v;
    }
    const s = pos;
    while (peek() != 0 and !isSpace(peek()) and std.mem.indexOfScalar(u8, "()';\"", peek()) == null) pos += 1;
    const t = src[s..pos];
    if (std.mem.indexOfAny(u8, t, "0123456789") != null) if (std.fmt.parseFloat(f64, t)) |d| return .{ .n = d } else |_| {};
    return .{ .s = mkstr(t, true) };
}

/// Iterative: `open` holds where each unfinished list starts in `done` (negative: a pending quote).
pub fn parse(text: []const u8) E!V {
    src = text;
    pos = 0;
    var done: std.ArrayList(V) = .empty;
    defer done.deinit(gpa);
    var open: std.ArrayList(isize) = .empty;
    defer open.deinit(gpa);
    while (true) {
        skip();
        var d: V = undefined;
        switch (peek()) {
            0 => return fail(str("ToyLisp: Syntax error, unbalanced expression", .{})),
            '(', '\'' => |c| {
                pos += 1;
                const n: isize = @intCast(done.items.len);
                gc.push(isize, &open, if (c == '(') n else -n - 1);
                continue;
            },
            ')' => {
                pos += 1;
                if (open.items.len == 0 or open.getLast() < 0) return fail(str("ToyLisp: Syntax error, unexpected closing parenthesis", .{}));
                const s: usize = @intCast(open.pop().?);
                d = list(done.items[s..], done.items.len - s);
                done.items.len = s;
            },
            else => d = atom(),
        }
        while (open.items.len > 0 and open.getLast() == -@as(isize, @intCast(done.items.len)) - 1) : (_ = open.pop()) d = list(&.{ .{ .s = mkstr("quote", true) }, d }, 2);
        gc.push(V, &done, d);
        if (open.items.len == 0) break;
    }
    skip();
    if (peek() != 0) return fail(str("ToyLisp: Syntax error, unexpected closing parenthesis", .{}));
    return done.items[0];
}

// ---------------------------------------------------------------- scopes
const HSIZE = 1 << 13;
var hk: [HSIZE]?[*:0]const u8 = @splat(null);
var hv: [HSIZE]V = @splat(.nil);

/// Root scope: global hash table; lambda scopes: small arrays.
fn slot(e: *Env, k: [*:0]const u8, create: bool) ?*V {
    if (e.p == null) {
        var h: u32 = 2166136261;
        var c: usize = 0;
        while (k[c] != 0) : (c += 1) h = (h ^ k[c]) *% 16777619;
        h &= HSIZE - 1;
        while (hk[h]) |key| : (h = (h + 1) & (HSIZE - 1)) if (streq(key, k)) return &hv[h];
        if (!create) return null;
        hk[h] = k;
        return &hv[h];
    }
    var i = e.n;
    while (i > 0) {
        i -= 1;
        if (e.k[i] == k or streq(e.k[i], k)) return &e.v[i];
    }
    if (!create) return null;
    if (e.n == e.cap) {
        e.cap *= 2;
        const v2: [*]V = @ptrCast(@alignCast(gc.raw(e.cap * (@sizeOf(V) + @sizeOf([*:0]const u8)))));
        const k2: [*][*:0]const u8 = @ptrCast(v2 + e.cap); // keys follow values
        @memcpy(v2[0..e.n], e.v[0..e.n]);
        @memcpy(k2[0..e.n], e.k[0..e.n]);
        if (e.v != gc.after(V, e)) gc.rawFree(e.v);
        e.v = v2;
        e.k = k2;
    }
    e.k[e.n] = k;
    e.v[e.n] = .nil;
    e.n += 1;
    return &e.v[e.n - 1];
}

fn name(v: V) [*:0]const u8 {
    return if (v == .s) v.s else str("{f}", .{v}).s;
}

pub fn get(env: *Env, k: [*:0]const u8) V {
    var e: ?*Env = env;
    while (e) |s| : (e = s.p) if (slot(s, k, false)) |v| return v.*;
    return .nil;
}

/// Root keys are copied to permanent memory; scope keys are counted references.
pub fn set(e: *Env, key: [*:0]const u8, v: V) void {
    const s = slot(e, key, false) orelse blk: {
        var k = key;
        if (e.p != null) gc.ret(@ptrCast(@constCast(k))) else {
            k = mkstr(std.mem.span(k), true);
            if (std.mem.startsWith(u8, std.mem.span(k), "macro/")) {
                macros[nmacros] = k;
                nmacros += 1;
            }
        }
        break :blk slot(e, k, true).?;
    };
    gc.rel(ptr(s.*));
    s.* = rv(v);
}

fn newEnv(p: ?*Env, min_cap: usize) *Env {
    const cap = @max(min_cap, 4);
    const size = @sizeOf(Env) + cap * (@sizeOf(V) + @sizeOf([*:0]const u8));
    const e: *Env = @ptrCast(@alignCast(if (p != null) gc.alloc(size, .env) else gc.perm(size)));
    gc.ret(p);
    e.* = .{ .p = p, .n = 0, .cap = cap, .v = gc.after(V, e), .k = @ptrCast(gc.after(V, e) + cap) };
    return e;
}

fn bind(f: *Lam, a: []const V) *Env {
    const ps = items(f.params);
    const e = newEnv(f.env, ps.len);
    for (ps, 0..) |p, i| {
        e.k[i] = name(p);
        gc.ret(@ptrCast(@constCast(e.k[i])));
        e.v[i] = rv(arg(a, i));
    }
    e.n = ps.len;
    return e;
}

// ---------------------------------------------------------------- evaluator
// Pending work lives in heap frames: Lisp recursion never grows the native stack.
const Frame = enum { @"if", begin, define, apply }; // define: define or set!
const K = struct { kind: Frame, i: usize, base: usize, mark: usize, l: []V, e: *Env };
var ks: std.ArrayList(K) = .empty; // frame stack
var vs: std.ArrayList(V) = .empty; // operand stack: evaluated function + arguments
var depth: usize = 0; // natives calling back into Lisp (map, try, ...) re-enter eval on the native stack

pub fn call(f: V, a: []const V) E!V {
    switch (f) {
        .f => |n| return n.f(n, a),
        .lam => |l| {
            const m = gc.mark();
            return gc.sweepKeep(m, try eval(l.body, bind(l, a)), null);
        },
        else => return fail(str("ToyLisp: {f} is not a function", .{f})),
    }
}

/// Every `macro/*` in the root scope sees every node before it's evaluated.
fn expand(node: V, env: *Env) E!V {
    if (in_macro) return node;
    var root = env;
    while (root.p) |p| root = p;
    var x = node;
    for (macros[0..nmacros]) |m| {
        in_macro = true;
        const y = try call(get(root, m), &.{x});
        in_macro = false;
        if (truthy(y)) x = y;
    }
    return x;
}

fn is(h: [*:0]const u8, comptime s: [:0]const u8) bool {
    return streq(h, s);
}

pub fn eval(node: V, env: *Env) E!V {
    var m0 = gc.mark();
    const base = ks.items.len;
    var x = node;
    var e = env;
    depth += 1;
    if (depth > 8000) return fail(str("ToyLisp: recursion too deep (over 8000 nested calls made by native functions)", .{}));
    ev: while (true) {
        x = try expand(x, e);
        var v: V = switch (x) {
            .s => |s| get(e, s),
            .lit => |s| .{ .s = s },
            .l => |l| blk: {
                const a = l.a;
                if (a.len == 0) return fail(str("ToyLisp: cannot evaluate an empty list", .{}));
                const h: [*:0]const u8 = if (a[0] == .s) a[0].s else "";
                if (is(h, "quote")) break :blk arg(a, 1);
                if (is(h, "lambda")) {
                    const f = gc.new(Lam, 0, .lam);
                    f.* = .{ .params = rv(arg(a, 1)), .body = rv(arg(a, 2)), .env = e };
                    gc.ret(e);
                    break :blk .{ .lam = f };
                }
                if (is(h, "begin") and a.len < 3) {
                    if (a.len == 1) break :blk .nil;
                    x = a[1];
                    continue :ev;
                }
                const kind: Frame = if (is(h, "if")) .@"if" else if (is(h, "begin")) .begin else if (is(h, "define") or is(h, "set!")) .define else .apply;
                const i: usize = switch (kind) {
                    .apply => 0,
                    .define => 2,
                    else => 1,
                };
                gc.push(K, &ks, .{ .kind = kind, .i = i, .base = vs.items.len, .mark = gc.mark(), .l = a, .e = e });
                x = arg(a, i);
                continue :ev;
            },
            else => x,
        };
        while (true) { // hand v to the innermost frame
            if (ks.items.len == base) {
                depth -= 1;
                return gc.sweepKeep(m0, v, null);
            }
            const k = &ks.items[ks.items.len - 1];
            v = gc.sweepKeep(k.mark, v, null);
            const a = k.l;
            e = k.e;
            switch (k.kind) {
                .@"if" => { // tail position: no frame
                    ks.items.len -= 1;
                    x = if (truthy(v)) arg(a, 2) else arg(a, 3);
                    continue :ev;
                },
                .begin => {
                    k.i += 1;
                    x = a[k.i];
                    if (k.i == a.len - 1) ks.items.len -= 1 else k.mark = gc.mark();
                    continue :ev;
                },
                .define => {
                    ks.items.len -= 1;
                    const s = name(a[1]);
                    if (a[0].s[0] == 'd') set(e, s, v) else {
                        var p: ?*Env = e;
                        while (p) |scope| : (p = scope.p) if (slot(scope, s, false) != null) {
                            set(scope, s, v);
                            break;
                        };
                    }
                },
                .apply => {
                    if (k.i == 0 and v == .nil) return fail(str("ToyLisp: Function {f} is not defined", .{a[0]}));
                    gc.push(V, &vs, v);
                    k.i += 1;
                    if (k.i < a.len) {
                        k.mark = gc.mark();
                        x = a[k.i];
                        continue :ev;
                    }
                    const f = vs.items[k.base];
                    const n = a.len - 1;
                    var small: [16]V = undefined; // copy: natives may re-enter eval and grow vs
                    const args: []V = if (n <= small.len) small[0..n] else @as([*]V, @ptrCast(@alignCast(gc.raw(n * @sizeOf(V)))))[0..n];
                    defer if (n > small.len) gc.rawFree(args.ptr);
                    @memcpy(args, vs.items[k.base + 1 ..][0..n]);
                    vs.items.len = k.base;
                    ks.items.len -= 1;
                    if (f != .lam) {
                        v = try call(f, args);
                        continue;
                    }
                    e = bind(f.lam, args); // tail call: only x and e stay live
                    x = f.lam.body;
                    const mk = if (ks.items.len > base) &ks.items[ks.items.len - 1].mark else &m0;
                    mk.* = gc.resweep(mk.*, x, e);
                    continue :ev;
                },
            }
        }
    }
}

// ---------------------------------------------------------------- primitives
fn binop(op: usize, x: V, y: V) V {
    const a = num(x);
    const b = num(y);
    return switch (op) {
        0 => if (x == .s or x == .lit or y == .s or y == .lit) str("{f}{f}", .{ x, y }) else .{ .n = a + b },
        1 => .{ .n = a - b },
        2 => .{ .n = a * b },
        3 => .{ .n = a / b },
        4 => .{ .b = a > b },
        5 => .{ .b = a < b },
        6 => .{ .b = a >= b },
        7 => .{ .b = a <= b },
        8 => if (truthy(x)) y else x,
        else => if (truthy(x)) x else y,
    };
}

const core = struct {
    fn arith(s: *Fn, a: []const V) E!V {
        var r = arg(a, 0);
        for (a[@min(1, a.len)..]) |x| r = binop(s.i, r, x);
        return r;
    }
    fn eqp(_: *Fn, a: []const V) E!V {
        for (a) |x| if (!eq(x, a[0])) return .{ .b = false };
        return .{ .b = true };
    }
    fn car(_: *Fn, a: []const V) E!V {
        return arg(items(arg(a, 0)), 0);
    }
    fn cdr(_: *Fn, a: []const V) E!V {
        const l = items(arg(a, 0));
        return if (l.len > 0) list(l[1..], l.len - 1) else list(null, 0);
    }
    fn len(_: *Fn, a: []const V) E!V {
        return .{ .n = @floatFromInt(items(arg(a, 0)).len) };
    }
    fn lst(_: *Fn, a: []const V) E!V {
        return list(a, a.len);
    }
    fn err(_: *Fn, a: []const V) E!V {
        return fail(arg(a, 0));
    }
    fn cons(_: *Fn, a: []const V) E!V {
        const l = items(arg(a, 1));
        const r = list(null, l.len + 1);
        r.l.a[0] = rv(arg(a, 0));
        for (l, r.l.a[1..]) |x, *y| y.* = rv(x);
        return r;
    }
    fn try_(_: *Fn, a: []const V) E!V { // on error, drop the frames of the aborted evaluation
        const im = in_macro;
        const k0 = ks.items.len;
        const v0 = vs.items.len;
        const d0 = depth;
        return call(arg(a, 0), &.{}) catch {
            in_macro = im;
            ks.items.len = k0;
            vs.items.len = v0;
            depth = d0;
            return call(arg(a, 1), &.{errv});
        };
    }
    // trampoline: nested calls while active return thunks, the outermost runs them
    fn thunk(s: *Fn, _: []const V) E!V {
        return call(s.d0, s.d1.l.a);
    }
    fn trampRun(s: *Fn, a: []const V) E!V {
        if (s.i != 0) return .{ .f = nf(thunk, s.d0, list(a, a.len)) };
        var m = gc.mark();
        s.i = 1;
        var r = try call(s.d0, a);
        while (r == .f or r == .lam) {
            r = try call(r, &.{});
            m = gc.resweep(m, r, null);
        }
        s.i = 0;
        return r;
    }
    fn trampoline(_: *Fn, a: []const V) E!V {
        return .{ .f = nf(trampRun, arg(a, 0), .nil) };
    }
};

pub fn def(e: *Env, k: [*:0]const u8, f: *const fn (*Fn, []const V) E!V) void {
    set(e, k, .{ .f = nf(f, .nil, .nil) });
}

fn topLevel() *Env {
    const e = newEnv(null, 0);
    set(e, "nil", .nil);
    set(e, "#t", .{ .b = true });
    set(e, "#f", .{ .b = false });
    for ([_][*:0]const u8{ "+", "-", "*", "/", ">", "<", ">=", "<=", "&&", "||" }, 0..) |op, i| {
        const f = nf(core.arith, .nil, .nil);
        f.i = i;
        set(e, op, .{ .f = f });
    }
    def(e, "eq?", core.eqp);
    def(e, "car", core.car);
    def(e, "cdr", core.cdr);
    def(e, "len", core.len);
    def(e, "cons", core.cons);
    def(e, "list", core.lst);
    def(e, "error", core.err);
    def(e, "try", core.try_);
    def(e, "trampoline", core.trampoline);
    return e;
}

// ---------------------------------------------------------------- CLI
fn load(io: std.Io, e: *Env, path: []const u8) E!void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch return fail(str("cannot open {s}", .{path}));
    defer gpa.free(text);
    const program = std.fmt.allocPrint(gpa, "(begin {s}\n)", .{text}) catch gc.oom();
    defer gpa.free(program);
    _ = try eval(try parse(program), e);
    _ = gc.sweepKeep(0, .nil, null);
}

fn die() noreturn {
    out.flush() catch {};
    std.debug.print("\x1b[31m{f}\x1b[39m\n", .{errv});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var obuf: [4096]u8 = undefined;
    var ow: std.Io.File.Writer = .init(.stdout(), init.io, &obuf);
    out = &ow.interface;
    defer out.flush() catch {};
    const e = topLevel();
    var file: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--debug")) {
            set(e, "*DEBUG*", .{ .b = true });
            try out.writeAll("\x1b[33mDebug mode enabled\x1b[39m\n");
        }
        if (std.mem.eql(u8, a, "-f") and i + 1 < args.len) file = args[i + 1];
    }
    native.install(e);
    load(init.io, e, "src/stdlib.lisp") catch die();
    if (file) |f| return load(init.io, e, f) catch die();
    const ibuf = try gpa.alloc(u8, 1 << 24);
    var in: std.Io.File.Reader = .init(.stdin(), init.io, ibuf);
    while (true) : (_ = gc.sweepKeep(0, .nil, null)) {
        try out.writeAll("#> ");
        try out.flush();
        const line = try in.interface.takeDelimiter('\n') orelse return;
        const s = std.mem.trimStart(u8, line, " \t\r\n");
        if (s.len == 0) continue;
        if (parse(s)) |x| if (eval(x, e)) |v| {
            try out.print("\x1b[32m{f}\x1b[39m\n", .{v});
            continue;
        } else |_| {} else |_| {}
        in_macro = false;
        ks.items.len = 0;
        vs.items.len = 0;
        depth = 0;
        try out.print("\x1b[31m{f}\x1b[39m\n", .{errv});
    }
}
