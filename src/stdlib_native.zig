// Native part of the stdlib (installed before src/stdlib.lisp is loaded).
const std = @import("std");
const lisp = @import("lang.zig");
const gc = @import("gc.zig");
const V = lisp.V;
const Fn = lisp.Fn;
const E = lisp.E;
const arg = lisp.arg;

fn print(_: *Fn, a: []const V) E!V {
    for (a, 0..) |v, i| lisp.out.print("{s}{f}", .{ if (i > 0) " " else "", v }) catch {};
    lisp.out.writeByte('\n') catch {};
    return .nil;
}

fn isList(_: *Fn, a: []const V) E!V {
    return .{ .b = arg(a, 0) == .l };
}

fn at(_: *Fn, a: []const V) E!V {
    const l = lisp.items(arg(a, 0));
    const i = lisp.num(arg(a, 1));
    return if (i >= 0 and i < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(i)] else .nil;
}

fn map(_: *Fn, a: []const V) E!V {
    const l = lisp.items(arg(a, 0));
    const r = lisp.list(&.{}, l.len);
    for (l, r.l.a) |*x, *y| y.* = lisp.rv(try lisp.call(arg(a, 1), x[0..1])); // results are stored in the heap: count them
    return r;
}

fn reduce(_: *Fn, a: []const V) E!V {
    var m = arg(a, 2);
    for (lisp.items(arg(a, 0))) |x| m = try lisp.call(arg(a, 1), &.{ m, x });
    return m;
}

fn red(_: *Fn, a: []const V) E!V {
    return lisp.str("\x1b[31m{f}\x1b[39m", .{arg(a, 0)});
}

fn green(_: *Fn, a: []const V) E!V {
    return lisp.str("\x1b[32m{f}\x1b[39m", .{arg(a, 0)});
}

fn partialRun(s: *Fn, a: []const V) E!V {
    const pre = lisp.items(s.d1);
    const args = std.mem.concat(std.heap.c_allocator, V, &.{ pre, a }) catch gc.oom(); // heap: the prefix list can be large
    defer std.heap.c_allocator.free(args);
    return lisp.call(s.d0, args);
}

fn partial(_: *Fn, a: []const V) E!V {
    return .{ .f = lisp.nf(partialRun, arg(a, 0), arg(a, 1)) };
}

fn def(e: *lisp.Env, k: [*:0]const u8, f: *const fn (*Fn, []const V) E!V) void {
    lisp.set(e, k, .{ .f = lisp.nf(f, .nil, .nil) });
}

pub fn install(e: *lisp.Env) void {
    lisp.set(e, "pi", .{ .n = std.math.pi });
    def(e, "print", print);
    def(e, "list?", isList);
    def(e, "at", at);
    def(e, "map", map);
    def(e, "reduce", reduce);
    def(e, "red", red);
    def(e, "green", green);
    def(e, "partial", partial);
}
