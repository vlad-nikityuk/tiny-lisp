// Native part of the stdlib (installed before src/stdlib.lisp is loaded).
const std = @import("std");
const source = @import("source.zig");
const lang = @import("lang.zig");
const gc = @import("gc.zig");
const runtime = @import("runtime.zig");
const V = runtime.V;
const Fn = runtime.Fn;
const K = runtime.K;
const Go = runtime.Go;
const E = runtime.E;
const arg = runtime.arg;

fn print(_: *Fn, a: []const V) E!V {
    for (a, 0..) |v, i| lang.out.print("{s}{f}", .{ if (i > 0) " " else "", v }) catch {};
    lang.out.writeByte('\n') catch {};
    return .nil;
}

fn isList(_: *Fn, a: []const V) E!V {
    return V.boolean(arg(a, 0).is(.l));
}

// map and reduce call back into Lisp, so they run as frames (see runtime.zig).
// (map l1 ... ln f) calls f with the next item of every list, as many times as the shortest list is long:
// vs holds the lists and f after the native, then the results and the number of arguments; k.i is the next index.
fn mapper(comptime keep: bool) *const fn (*Fn, *K, ?V) E!Go {
    return struct {
        fn f(_: *Fn, k: *K, v: ?V) E!Go {
            const vs = &runtime.vs;
            if (v == null) {
                const n = vs.items.len - k.base - 1;
                var len: usize = if (n < 2) 0 else std.math.maxInt(usize);
                if (n >= 2) for (vs.items[k.base + 1 ..][0 .. n - 1]) |l| {
                    len = @min(len, runtime.items(l).len);
                };
                gc.push(V, vs, if (keep) runtime.list(&.{}, len) else V.num(@floatFromInt(len))); // each keeps only the count
                gc.push(V, vs, V.num(@floatFromInt(n)));
            }
            const n: usize = @intFromFloat(vs.items[vs.items.len - 1].asNum());
            const state = vs.items[vs.items.len - 2];
            if (v) |r| {
                if (keep) state.asList().items()[k.i] = r;
                k.i += 1;
            }
            if (k.i == (if (keep) state.asList().items().len else @as(usize, @intFromFloat(state.asNum())))) return runtime.finish(k, if (keep) state else .nil);
            var xs: [8]V = undefined;
            std.debug.assert(n - 1 <= xs.len);
            for (vs.items[k.base + 1 ..][0 .. n - 1], xs[0 .. n - 1]) |l, *x| x.* = runtime.items(l)[k.i];
            return runtime.callback(vs.items[k.base + n], xs[0 .. n - 1]);
        }
    }.f;
}

fn reduce(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| {
        runtime.vs.items[k.base + 3] = r;
        k.i += 1;
    } else _ = runtime.frameArgs(k, 3);
    const s = runtime.vs.items[k.base + 1 ..];
    const l = runtime.items(s[0]);
    return if (k.i < l.len) runtime.callback(s[1], &.{ s[2], l[k.i] }) else runtime.finish(k, s[2]);
}

/// (concat l1 l2 ...) is one list with all their items: a single copy, however many lists.
fn concat(_: *Fn, a: []const V) E!V {
    var n: usize = 0;
    for (a) |l| n += runtime.items(l).len;
    const r = runtime.list(&.{}, n);
    var i: usize = 0;
    for (a) |l| for (runtime.items(l)) |x| {
        r.asList().items()[i] = x;
        i += 1;
    };
    return r;
}

/// (range n) is the list (0 1 ... n-1).
fn range(_: *Fn, a: []const V) E!V {
    const r = runtime.list(&.{}, runtime.rangeLen(arg(a, 0)));
    for (r.asList().items(), 0..) |*x, i| x.* = V.num(@floatFromInt(i));
    return r;
}

/// (zip l1 l2) is the list of pairs (a b), as long as the shorter list.
fn zip(_: *Fn, a: []const V) E!V {
    const x, const y = .{ runtime.items(arg(a, 0)), runtime.items(arg(a, 1)) };
    const n = @min(x.len, y.len);
    const r = runtime.list(&.{}, n);
    for (r.asList().items(), x[0..n], y[0..n]) |*p, a_i, b_i| p.* = runtime.list(&.{ a_i, b_i }, 2);
    return r;
}

/// (apply f args) calls f with the items of the list args as its arguments.
fn apply(_: *Fn, k: *K, _: ?V) E!Go {
    const a = runtime.frameArgs(k, 2);
    return runtime.tail(k, a[0], runtime.items(a[1]), false);
}

fn partialRun(s: *Fn, k: *K, _: ?V) E!Go {
    return runtime.tail(k, s.d0, runtime.items(s.d1), true); // the fixed arguments go before the frame's
}

fn partial(_: *Fn, a: []const V) E!V {
    return V.fnOf(runtime.nf(.{ .step = partialRun }, arg(a, 0), arg(a, 1)));
}

// File IO is whole-file and stateless: open, read or write, close, all inside one call, so no handle is ever
// left open and nothing needs cleaning up. Failures raise a Lisp error.
pub var io: std.Io = undefined;
const gpa = std.heap.c_allocator;

fn text(v: V) []const u8 {
    return if (v.is(.s) or v.is(.lit)) std.mem.span(v.asStr()) else "";
}

fn readFile(_: *Fn, a: []const V) E!V {
    const body = std.Io.Dir.cwd().readFileAlloc(io, text(arg(a, 0)), gpa, .unlimited) catch
        return runtime.fail(runtime.str("cannot read {s}", .{text(arg(a, 0))}));
    defer gpa.free(body);
    return V.string(runtime.mkstr(body, false));
}

fn writeFile(_: *Fn, a: []const V) E!V {
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = text(arg(a, 0)), .data = text(arg(a, 1)) }) catch
        return runtime.fail(runtime.str("cannot write {s}", .{text(arg(a, 0))}));
    return .nil;
}

/// (split "a,b" ",") -> (a b); an empty separator splits into single characters.
fn split(_: *Fn, a: []const V) E!V {
    const s = text(arg(a, 0));
    const sep = text(arg(a, 1));
    var parts: std.ArrayList(V) = .empty;
    defer parts.deinit(gpa);
    if (sep.len == 0) {
        for (s) |c| gc.push(V, &parts, V.string(runtime.mkstr(&.{c}, false)));
    } else {
        var it = std.mem.splitSequence(u8, s, sep);
        while (it.next()) |p| gc.push(V, &parts, V.string(runtime.mkstr(p, false)));
    }
    return runtime.list(parts.items, parts.items.len);
}

/// (load "file.lisp") evaluates the file's expressions in the caller's scope; the frame hands on the last value.
fn load(_: *Fn, k: *K, v: ?V) E!Go {
    if (v) |r| return runtime.finish(k, r);
    const path = text(runtime.frameArgs(k, 1)[0]);
    return .{ .eval = lang.stub(try source.readProgram(io, path)) };
}

fn def(e: *runtime.Env, k: [*:0]const u8, f: runtime.Native) V {
    const v = V.fnOf(runtime.nf(f, .nil, .nil));
    runtime.set(e, k, v);
    return v;
}

pub fn install(e: *runtime.Env) void {
    _ = def(e, "print", .{ .plain = print });
    _ = def(e, "list?", .{ .plain = isList });
    runtime.map_v = runtime.pin(def(e, "map", .{ .step = mapper(true) }));
    runtime.each_v = runtime.pin(def(e, "each", .{ .step = mapper(false) }));
    _ = def(e, "reduce", .{ .step = reduce });
    _ = def(e, "apply", .{ .step = apply });
    _ = def(e, "partial", .{ .plain = partial });
    _ = def(e, "concat", .{ .plain = concat });
    runtime.range_v = runtime.pin(def(e, "range", .{ .plain = range }));
    _ = def(e, "zip", .{ .plain = zip });
    _ = def(e, "read-file", .{ .plain = readFile });
    _ = def(e, "write-file", .{ .plain = writeFile });
    _ = def(e, "split", .{ .plain = split });
    _ = def(e, "load", .{ .step = load });
}
