// Foreign-function interface: dlopen/dlsym, a register-split C call, memory peek/poke, and a fixed pool of C→Lisp callbacks.
//
// DESIGN (see CLAUDE.md): No libffi. On AArch64 AAPCS64 and x86-64 SysV, integer/pointer and floating-point
// parameters are passed in two independent register sequences, so casting to fn(i64×8, f64×8) callconv(.c) reaches any
// non-variadic C function with up to eight of each, regardless of source parameter order. Limits: no struct-by-value,
// no variadic calls, f32 is widened to f64 for the call; int32/uint32 returns are narrowed in the Lisp DSL.
// Callbacks use a comptime stub pool; Lisp runs on a nested eval.exec (like macro expansion). Errors in callbacks are
// stored and re-raised when the surrounding ffi-call returns; they must not unwind through C.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const machine = @import("../runtime/machine.zig");
const eval = @import("../lang/eval.zig");
const V = value.V;
const E = value.E;
const Fn = value.Fn;
const arg = value.arg;

extern "c" fn dlopen(name: ?[*:0]const u8, mode: i32) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: ?*anyopaque) i32;
extern "c" fn dlerror() ?[*:0]const u8;
const RTLD_LAZY: i32 = 0x1;

/// Re-raised after the C call that faulted a callback returns (ffi-take-error clears it).
pub var pending_err: ?V = null;

const pool_n = 64;
const CallbackStub = *const fn (a0: i64, a1: i64, a2: i64, a3: i64) callconv(.c) i64;

var slots: [pool_n]V = undefined;
var slot_live: [pool_n]bool = undefined;
var pool_ready = false;

fn ensurePool() void {
    if (pool_ready) return;
    for (&slots) |*s| s.* = .nil;
    for (&slot_live) |*b| b.* = false;
    pool_ready = true;
}

fn ptrNum(p: usize) V {
    if (p < (1 << 53)) return V.num(@floatFromInt(p));
    return V.num(@bitCast(@as(u64, @intCast(p))));
}

fn numPtr(v: V) E!usize {
    if (!v.isNum()) return value.fail(value.str("TinyLisp: FFI pointer must be a number", .{}));
    const x = v.asNum();
    if (x == @floor(x) and x >= 0 and x < 9007199254740992.0) // 2^53
        return @intFromFloat(x);
    return @intCast(@as(u64, @bitCast(x)));
}

fn fillRegs(a: []const V, comptime n: usize, out: *[n]i64) E!void {
    if (a.len > n) return value.fail(value.str("TinyLisp: FFI call has too many integer arguments (max {d})", .{n}));
    for (out, 0..) |*r, i| r.* = if (i < a.len) blk: {
        const v = a[i];
        if (!v.isNum()) return value.fail(value.str("TinyLisp: FFI integer argument must be a number", .{}));
        const x = v.asNum();
        if (x == @floor(x) and x >= 0 and x < 9007199254740992.0) break :blk @intFromFloat(x);
        break :blk @bitCast(@as(u64, @bitCast(x)));
    } else 0;
}

fn fillFloats(a: []const V, out: *[8]f64) E!void {
    if (a.len > 8) return value.fail(value.str("TinyLisp: FFI call has too many float arguments (max 8)", .{}));
    for (out, 0..) |*r, i| r.* = if (i < a.len) arg(a, i).asNum() else 0;
}

const Ci64 = *const fn (i0: i64, i1: i64, i2: i64, i3: i64, i4: i64, i5: i64, i6: i64, i7: i64, f0: f64, f1: f64, f2: f64, f3: f64, f4: f64, f5: f64, f6: f64, f7: f64) callconv(.c) i64;
const Cf64 = *const fn (i0: i64, i1: i64, i2: i64, i3: i64, i4: i64, i5: i64, i6: i64, i7: i64, f0: f64, f1: f64, f2: f64, f3: f64, f4: f64, f5: f64, f6: f64, f7: f64) callconv(.c) f64;
const Cvoid = *const fn (i0: i64, i1: i64, i2: i64, i3: i64, i4: i64, i5: i64, i6: i64, i7: i64, f0: f64, f1: f64, f2: f64, f3: f64, f4: f64, f5: f64, f6: f64, f7: f64) callconv(.c) void;

fn invoke(comptime Ret: enum { i64, f64, void }, ptr: usize, ints: []const V, floats: []const V) E!V {
    var ir: [8]i64 = undefined;
    var fr: [8]f64 = undefined;
    try fillRegs(ints, 8, &ir);
    try fillFloats(floats, &fr);
    const f = @as(*anyopaque, @ptrFromInt(ptr));
    switch (Ret) {
        .i64 => {
            const cfn: Ci64 = @ptrCast(@alignCast(f));
            const r = cfn(ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], ir[6], ir[7], fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7]);
            return ptrNum(@bitCast(r));
        },
        .f64 => {
            const cfn: Cf64 = @ptrCast(@alignCast(f));
            const r = cfn(ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], ir[6], ir[7], fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7]);
            return V.num(r);
        },
        .void => {
            const cfn: Cvoid = @ptrCast(@alignCast(f));
            cfn(ir[0], ir[1], ir[2], ir[3], ir[4], ir[5], ir[6], ir[7], fr[0], fr[1], fr[2], fr[3], fr[4], fr[5], fr[6], fr[7]);
            return .nil;
        },
    }
}

fn finishCall(v: V) E!V {
    if (pending_err) |e| {
        pending_err = null;
        value.errv = e;
        return error.Lisp;
    }
    return v;
}

fn dlopenNative(_: *Fn, a: []const V) E!V {
    const path: ?[*:0]const u8 = if (arg(a, 0).is(.nil)) null else arg(a, 0).asStr();
    const h = dlopen(path, RTLD_LAZY);
    if (h == null) return value.fail(value.str("TinyLisp: dlopen failed: {s}", .{dlerror() orelse "unknown"}));
    return ptrNum(@intFromPtr(h));
}

fn dlopenSelf(_: *Fn, _: []const V) E!V {
    const paths = [_][*:0]const u8{ "/usr/lib/libSystem.B.dylib", "libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6" };
    for (paths) |path| {
        if (dlopen(path, RTLD_LAZY)) |h| return ptrNum(@intFromPtr(h));
    }
    return value.fail(value.str("TinyLisp: dlopen self failed", .{}));
}

fn dlsymNative(_: *Fn, a: []const V) E!V {
    const h = try numPtr(arg(a, 0));
    const name = std.mem.span(arg(a, 1).asStr());
    const p = dlsym(@ptrFromInt(h), name);
    if (p == null) return value.fail(value.str("TinyLisp: dlsym {s} failed", .{name}));
    return ptrNum(@intFromPtr(p));
}

fn dlcloseNative(_: *Fn, a: []const V) E!V {
    _ = dlclose(@ptrFromInt(try numPtr(arg(a, 0))));
    return .nil;
}

fn callI64(_: *Fn, a: []const V) E!V {
    const r = try invoke(.i64, try numPtr(arg(a, 0)), value.items(arg(a, 1)), value.items(arg(a, 2)));
    return finishCall(r);
}

fn callF64(_: *Fn, a: []const V) E!V {
    const r = try invoke(.f64, try numPtr(arg(a, 0)), value.items(arg(a, 1)), value.items(arg(a, 2)));
    return finishCall(r);
}

fn callVoid(_: *Fn, a: []const V) E!V {
    const r = try invoke(.void, try numPtr(arg(a, 0)), value.items(arg(a, 1)), value.items(arg(a, 2)));
    return finishCall(r);
}

fn mallocNative(_: *Fn, a: []const V) E!V {
    const n = @as(usize, @intFromFloat(arg(a, 0).asNum()));
    const p = std.c.malloc(n) orelse return value.fail(value.str("TinyLisp: malloc failed", .{}));
    return ptrNum(@intFromPtr(p));
}

fn freeNative(_: *Fn, a: []const V) E!V {
    std.c.free(@ptrFromInt(try numPtr(arg(a, 0))));
    return .nil;
}

fn peek(_: *Fn, a: []const V) E!V {
    const p: [*]const u8 = @ptrFromInt(try numPtr(arg(a, 0)));
    const w = @as(usize, @intFromFloat(arg(a, 1).asNum()));
    const signed = value.truthy(arg(a, 2));
    return switch (w) {
        1 => V.num(if (signed) @floatFromInt(@as(i8, @bitCast(p[0]))) else @floatFromInt(p[0])),
        2 => V.num(@floatFromInt(std.mem.readInt(i16, p[0..2], .little))),
        4 => if (signed) V.num(@floatFromInt(std.mem.readInt(i32, p[0..4], .little))) else V.num(@floatFromInt(std.mem.readInt(u32, p[0..4], .little))),
        8 => V.num(@floatFromInt(std.mem.readInt(i64, p[0..8], .little))),
        else => value.fail(value.str("TinyLisp: ffi-peek width must be 1, 2, 4, or 8", .{})),
    };
}

fn poke(_: *Fn, a: []const V) E!V {
    const p: [*]u8 = @ptrFromInt(try numPtr(arg(a, 0)));
    const w = @as(usize, @intFromFloat(arg(a, 1).asNum()));
    const v = arg(a, 2).asNum();
    switch (w) {
        1 => p[0] = @intCast(@as(i64, @intFromFloat(v))),
        2 => std.mem.writeInt(i16, p[0..2], @intCast(@as(i64, @intFromFloat(v))), .little),
        4 => std.mem.writeInt(i32, p[0..4], @intCast(@as(i64, @intFromFloat(v))), .little),
        8 => std.mem.writeInt(i64, p[0..8], @intCast(@as(i64, @intFromFloat(v))), .little),
        else => return value.fail(value.str("TinyLisp: ffi-poke width must be 1, 2, 4, or 8", .{})),
    }
    return .nil;
}

fn peekF64(_: *Fn, a: []const V) E!V {
    const p: [*]const u8 = @ptrFromInt(try numPtr(arg(a, 0)));
    return V.num(@as(*const f64, @ptrCast(@alignCast(p))).*);
}

fn pokeF64(_: *Fn, a: []const V) E!V {
    const p: [*]u8 = @ptrFromInt(try numPtr(arg(a, 0)));
    @as(*f64, @ptrCast(@alignCast(p))).* = arg(a, 1).asNum();
    return .nil;
}

fn copyCString(_: *Fn, a: []const V) E!V {
    const s: [*:0]const u8 = @ptrFromInt(try numPtr(arg(a, 0)));
    const n = std.mem.len(s);
    return V.string(value.mkstr(s[0..n], false));
}

fn cstrAlloc(_: *Fn, a: []const V) E!V {
    const t = std.mem.span(arg(a, 0).asStr());
    const p = std.c.malloc(t.len + 1) orelse return value.fail(value.str("TinyLisp: malloc failed", .{}));
    @memcpy(@as([*]u8, @ptrCast(p))[0..t.len], t);
    @as([*]u8, @ptrCast(p))[t.len] = 0;
    return ptrNum(@intFromPtr(p));
}

fn runCallback(comptime id: usize, args: [4]i64) i64 {
    if (!slot_live[id]) return 0;
    const f = slots[id];
    machine.callback_depth += 1;
    defer machine.callback_depth -= 1;
    const b = machine.vs.items.len;
    gc.push(V, &machine.vs, f);
    const xs = [_]V{ ptrNum(@bitCast(args[0])), ptrNum(@bitCast(args[1])), ptrNum(@bitCast(args[2])), ptrNum(@bitCast(args[3])) };
    machine.vs.appendSlice(value.gpa, &xs) catch {
        pending_err = value.str("TinyLisp: out of memory", .{});
        return 0;
    };
    const r = eval.exec(.{ .apply = b }, scope.root) catch {
        pending_err = value.errv;
        return 0;
    };
    if (r.isNum()) return @intFromFloat(r.asNum());
    return 0;
}

fn makeStub(comptime id: usize) CallbackStub {
    return struct {
        fn entry(a0: i64, a1: i64, a2: i64, a3: i64) callconv(.c) i64 {
            return runCallback(id, .{ a0, a1, a2, a3 });
        }
    }.entry;
}

const stub_table: [pool_n]CallbackStub = blk: {
    var t: [pool_n]CallbackStub = undefined;
    for (&t, 0..) |*s, i| s.* = makeStub(i);
    break :blk t;
};

fn registerCallback(_: *Fn, a: []const V) E!V {
    ensurePool();
    const f = arg(a, 0);
    if (!f.is(.lam) and !f.is(.f)) return value.fail(value.str("TinyLisp: ffi-register-callback needs a function", .{}));
    var id: ?usize = null;
    for (slot_live, 0..) |live, i| if (!live) {
        id = i;
        break;
    };
    const i = id orelse return value.fail(value.str("TinyLisp: FFI callback pool full ({d})", .{pool_n}));
    slots[i] = f;
    slot_live[i] = true;
    gc.push(V, &machine.ffi_roots, f);
    return V.num(@floatFromInt(i));
}

fn callbackPtr(_: *Fn, a: []const V) E!V {
    const i = @as(usize, @intFromFloat(arg(a, 0).asNum()));
    if (i >= pool_n or !slot_live[i]) return value.fail(value.str("TinyLisp: invalid FFI callback id", .{}));
    return ptrNum(@intFromPtr(stub_table[i]));
}

fn releaseCallback(_: *Fn, a: []const V) E!V {
    const i = @as(usize, @intFromFloat(arg(a, 0).asNum()));
    if (i >= pool_n or !slot_live[i]) return value.fail(value.str("TinyLisp: invalid FFI callback id", .{}));
    const f = slots[i];
    slots[i] = .nil;
    slot_live[i] = false;
    for (machine.ffi_roots.items, 0..) |v, j| {
        if (v == f) {
            machine.ffi_roots.items[j] = machine.ffi_roots.items[machine.ffi_roots.items.len - 1];
            machine.ffi_roots.items.len -= 1;
            break;
        }
    }
    return .nil;
}

fn takeError(_: *Fn, _: []const V) E!V {
    const e = pending_err orelse V.nil;
    pending_err = null;
    return e;
}

fn def(e: *scope.Env, k: [*:0]const u8, f: value.Native) void {
    scope.set(e, k, V.fnOf(value.nf(f, V.nil, V.nil)));
}

pub fn install(e: *scope.Env) void {
    ensurePool();
    def(e, "ffi-dlopen", .{ .plain = dlopenNative });
    def(e, "ffi-dlopen-self", .{ .plain = dlopenSelf });
    def(e, "ffi-dlsym", .{ .plain = dlsymNative });
    def(e, "ffi-dlclose", .{ .plain = dlcloseNative });
    def(e, "ffi-call-i64", .{ .plain = callI64 });
    def(e, "ffi-call-f64", .{ .plain = callF64 });
    def(e, "ffi-call-void", .{ .plain = callVoid });
    def(e, "ffi-malloc", .{ .plain = mallocNative });
    def(e, "ffi-free", .{ .plain = freeNative });
    def(e, "ffi-peek", .{ .plain = peek });
    def(e, "ffi-poke", .{ .plain = poke });
    def(e, "ffi-peek-f64", .{ .plain = peekF64 });
    def(e, "ffi-poke-f64", .{ .plain = pokeF64 });
    def(e, "ffi-string-at", .{ .plain = copyCString });
    def(e, "ffi-cstr", .{ .plain = cstrAlloc });
    def(e, "ffi-register-callback", .{ .plain = registerCallback });
    def(e, "ffi-callback-ptr", .{ .plain = callbackPtr });
    def(e, "ffi-release-callback", .{ .plain = releaseCallback });
    def(e, "ffi-take-error", .{ .plain = takeError });
}
