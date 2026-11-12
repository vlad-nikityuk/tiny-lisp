// Native part of the stdlib (installed before src/stdlib.lisp is loaded).
const std = @import("std");
const lang = @import("lang.zig");
const gc = @import("gc.zig");
const runtime = @import("runtime.zig");
const V = runtime.V;
const Fn = runtime.Fn;
const K = runtime.K;
const Go = runtime.Go;
const E = runtime.E;
const arg = runtime.arg;

/// Iterative, so nested lists can't overflow the native stack.
pub fn format(root: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var todo: std.ArrayList(?V) = .empty; // null: a list's closing parenthesis
    defer todo.deinit(std.heap.c_allocator);
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

fn print(_: *Fn, a: []const V) E!V {
    for (a, 0..) |v, i| lang.out.print("{s}{f}", .{ if (i > 0) " " else "", v }) catch {};
    lang.out.writeByte('\n') catch {};
    return .nil;
}

fn isList(_: *Fn, a: []const V) E!V {
    return .{ .b = arg(a, 0) == .l };
}

fn at(_: *Fn, a: []const V) E!V {
    const l = runtime.items(arg(a, 0));
    const i = runtime.num(arg(a, 1));
    return if (i >= 0 and i < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(i)] else .nil;
}

// map and reduce call back into Lisp, so they run as frames (see runtime.zig):
// vs holds (list f results-or-accumulator) after the native, k.i is the next index.
fn map(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| {
        runtime.vs.items[k.base + 3].l.a[k.i] = runtime.rv(r); // results are stored in the heap: count them
        k.i += 1;
    } else {
        const n = runtime.items(runtime.frameArgs(k, 2)[0]).len;
        gc.push(V, &runtime.vs, runtime.list(&.{}, n));
    }
    const s = runtime.vs.items[k.base + 1 ..];
    const l = runtime.items(s[0]);
    return if (k.i < l.len) runtime.callback(k, s[1], l[k.i..][0..1]) else runtime.finish(k, s[2]);
}

fn reduce(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| {
        runtime.vs.items[k.base + 3] = r;
        k.i += 1;
    } else _ = runtime.frameArgs(k, 3);
    const s = runtime.vs.items[k.base + 1 ..];
    const l = runtime.items(s[0]);
    return if (k.i < l.len) runtime.callback(k, s[1], &.{ s[2], l[k.i] }) else runtime.finish(k, s[2]);
}

fn partialRun(s: *Fn, k: *K, _: ?V) E!Go {
    return runtime.tail(k, s.d0, runtime.items(s.d1), true); // the fixed arguments go before the frame's
}

fn partial(_: *Fn, a: []const V) E!V {
    return .{ .f = runtime.nf(.{ .step = partialRun }, arg(a, 0), arg(a, 1)) };
}

fn def(e: *runtime.Env, k: [*:0]const u8, f: runtime.Native) void {
    runtime.set(e, k, .{ .f = runtime.nf(f, .nil, .nil) });
}

pub fn install(e: *runtime.Env) void {
    def(e, "print", .{ .plain = print });
    def(e, "list?", .{ .plain = isList });
    def(e, "at", .{ .plain = at });
    def(e, "map", .{ .step = map });
    def(e, "reduce", .{ .step = reduce });
    def(e, "partial", .{ .plain = partial });
}
