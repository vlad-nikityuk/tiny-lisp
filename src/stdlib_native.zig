// Native part of the stdlib (installed before src/stdlib.lisp is loaded).
const std = @import("std");
const lisp = @import("lang.zig");
const gc = @import("gc.zig");
const runtime = @import("runtime.zig");
const V = lisp.V;
const Fn = lisp.Fn;
const K = lisp.K;
const Go = lisp.Go;
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

// map and reduce call back into Lisp, so they run as frames (see runtime.zig):
// vs holds (list f results-or-accumulator) after the native, k.i is the next index.
fn map(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| {
        lisp.vs.items[k.base + 3].l.a[k.i] = lisp.rv(r); // results are stored in the heap: count them
        k.i += 1;
    } else {
        const n = lisp.items(runtime.frameArgs(k, 2)[0]).len;
        gc.push(V, &lisp.vs, lisp.list(&.{}, n));
    }
    const s = lisp.vs.items[k.base + 1 ..];
    const l = lisp.items(s[0]);
    return if (k.i < l.len) runtime.callback(k, s[1], l[k.i..][0..1]) else runtime.finish(k, s[2]);
}

fn reduce(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| {
        lisp.vs.items[k.base + 3] = r;
        k.i += 1;
    } else _ = runtime.frameArgs(k, 3);
    const s = lisp.vs.items[k.base + 1 ..];
    const l = lisp.items(s[0]);
    return if (k.i < l.len) runtime.callback(k, s[1], &.{ s[2], l[k.i] }) else runtime.finish(k, s[2]);
}

fn red(_: *Fn, a: []const V) E!V {
    return lisp.str("\x1b[31m{f}\x1b[39m", .{arg(a, 0)});
}

fn green(_: *Fn, a: []const V) E!V {
    return lisp.str("\x1b[32m{f}\x1b[39m", .{arg(a, 0)});
}

fn partialRun(s: *Fn, k: *K, _: ?V) E!Go {
    return runtime.tail(k, s.d0, lisp.items(s.d1), true); // the fixed arguments go before the frame's
}

fn partial(_: *Fn, a: []const V) E!V {
    return .{ .f = lisp.nf(.{ .step = partialRun }, arg(a, 0), arg(a, 1)) };
}

fn def(e: *lisp.Env, k: [*:0]const u8, f: runtime.Native) void {
    lisp.set(e, k, .{ .f = lisp.nf(f, .nil, .nil) });
}

pub fn install(e: *lisp.Env) void {
    lisp.set(e, "pi", .{ .n = std.math.pi });
    def(e, "print", .{ .plain = print });
    def(e, "list?", .{ .plain = isList });
    def(e, "at", .{ .plain = at });
    def(e, "map", .{ .step = map });
    def(e, "reduce", .{ .step = reduce });
    def(e, "red", .{ .plain = red });
    def(e, "green", .{ .plain = green });
    def(e, "partial", .{ .plain = partial });
}
