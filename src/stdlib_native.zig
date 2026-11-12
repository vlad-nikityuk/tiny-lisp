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

fn print(_: *Fn, a: []const V) E!V {
    for (a, 0..) |v, i| lang.out.print("{s}{f}", .{ if (i > 0) " " else "", v }) catch {};
    lang.out.writeByte('\n') catch {};
    return .nil;
}

fn isList(_: *Fn, a: []const V) E!V {
    return V.boolean(arg(a, 0).is(.l));
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
        runtime.vs.items[k.base + 3].asList().items()[k.i] = r;
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
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch
        return runtime.fail(runtime.str("cannot open {s}", .{path}));
    defer gpa.free(body);
    const program = std.fmt.allocPrint(gpa, "(begin {s}\n)", .{body}) catch gc.oom();
    defer gpa.free(program);
    return .{ .eval = lang.stub(try lang.parse(program)) };
}

fn def(e: *runtime.Env, k: [*:0]const u8, f: runtime.Native) void {
    runtime.set(e, k, V.fnOf(runtime.nf(f, .nil, .nil)));
}

pub fn install(e: *runtime.Env) void {
    def(e, "print", .{ .plain = print });
    def(e, "list?", .{ .plain = isList });
    def(e, "at", .{ .plain = at });
    def(e, "map", .{ .step = map });
    def(e, "reduce", .{ .step = reduce });
    def(e, "partial", .{ .plain = partial });
    def(e, "concat", .{ .plain = concat });
    def(e, "read-file", .{ .plain = readFile });
    def(e, "write-file", .{ .plain = writeFile });
    def(e, "split", .{ .plain = split });
    def(e, "load", .{ .step = load });
}
