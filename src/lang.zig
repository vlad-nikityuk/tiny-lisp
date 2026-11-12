// zig fmt: off
const std = @import("std"); const gc = @import("gc.zig"); const runtime = @import("runtime.zig");
const V = runtime.V; const E = runtime.E; const str = runtime.str; const list = runtime.list; const arg = runtime.arg; const fail = runtime.fail;
const ks = &runtime.ks; const vs = &runtime.vs;
pub var out: *std.Io.Writer = undefined; pub var errv: V = .nil; var in_macro = false;
const M = struct { go: runtime.Go, e: *runtime.Env, m0: usize, base: usize }; // a machine run: this eval's frames are ks[base..]

// Macro expansion is the only nested machine: macros don't expand inside macros, so it nests once.
fn call(f: V, x: V) E!V {
    const b = vs.items.len; defer vs.items.len = b; gc.push(V, vs, f); gc.push(V, vs, x); return exec(.{ .apply = b }, undefined);
}
// Run until this run's frames are done. An error resumes at the innermost `try` frame of this run, if any.
pub fn eval(node: V, env: *runtime.Env) E!V { return exec(.{ .eval = node }, env); }
fn exec(go: runtime.Go, env: *runtime.Env) E!V {
    var m: M = .{ .go = go, .e = env, .m0 = gc.mark(), .base = ks.items.len }; const vbase = vs.items.len;
    errdefer ks.items.len, vs.items.len = .{ m.base, vbase };
    while (true) return run(&m) catch |err| { m.go = runtime.recover(m.base) orelse return err; continue; };
}
fn run(m: *M) E!V {
    var e = m.e;
    sw: switch (m.go) {
        .eval => |node| {
            var x = node; if (!in_macro) { in_macro = true; defer in_macro = false; for (runtime.macros.items) |p| { const y = try call(p.*, x); if (runtime.truthy(y)) x = y; } }
            switch (x) {
                .s => |s| continue :sw .{ .ret = if (runtime.lookup(e, s)) |p| p.* else .nil },
                .lit => |s| continue :sw .{ .ret = .{ .s = s } },
                .l => |l| {
                    const a = l.a; if (a.len == 0) return fail(str("ToyLisp: cannot evaluate an empty list", .{}));
                    const f = if (a[0] == .s) std.meta.stringToEnum(runtime.Form, std.mem.span(a[0].s)) orelse .apply else .apply; const kind = if (f == .native) .apply else f;
                    if (kind == .quote) continue :sw .{ .ret = arg(a, 1) };
                    if (kind == .lambda) continue :sw .{ .ret = runtime.lambda(a, e) };
                    const i: usize = if (kind == .apply) 0 else if (kind == .define or kind == .@"set!") 2 else 1;
                    if (kind != .begin or a.len > 2) gc.push(runtime.K, ks, .{ .kind = kind, .i = i, .base = vs.items.len, .mark = gc.mark(), .l = a, .e = e });
                    continue :sw .{ .eval = arg(a, i) };
                },
                else => continue :sw .{ .ret = x },
            }
        },
        .ret => |r| {
            if (ks.items.len == m.base) return gc.sweepKeep(m.m0, r);
            const k = &ks.items[ks.items.len - 1]; const v = gc.sweepKeep(k.mark, r); const a = k.l; e = k.e;
            switch (k.kind) {
                .@"if" => { ks.items.len -= 1; continue :sw .{ .eval = if (runtime.truthy(v)) arg(a, 2) else arg(a, 3) }; }, // tail position
                .begin => { k.i += 1; const x = a[k.i]; if (k.i == a.len - 1) ks.items.len -= 1 else k.mark = gc.mark(); continue :sw .{ .eval = x }; },
                .define, .@"set!" => { try runtime.assign(k.kind == .define, a, e, v); ks.items.len -= 1; continue :sw .{ .ret = v }; },
                .native => continue :sw try runtime.step(k, v),
                else => { // apply: collect the function and its arguments on vs
                    if (k.i == 0 and v == .nil) return fail(str("ToyLisp: Function {f} is not defined", .{a[0]}));
                    gc.push(V, vs, v); k.i += 1; if (k.i < a.len) { k.mark = gc.mark(); continue :sw .{ .eval = a[k.i] }; }
                    ks.items.len -= 1; continue :sw .{ .apply = k.base };
                },
            }
        },
        .apply => |b| { // in tail position of the innermost frame
            const f = vs.items[b]; const args = vs.items[b + 1 ..]; switch (f) {
                .lam => |l| { // tail call: only the body and e stay live
                    e = runtime.bind(l, args); vs.items.len = b; const x = l.body; const mk = if (ks.items.len > m.base) &ks.items[ks.items.len - 1].mark else &m.m0;
                    mk.* = gc.resweep(mk.*, x, e); continue :sw .{ .eval = x };
                },
                .f => |n| switch (n.f) {
                    .plain => |p| { const v = try p(n, args); vs.items.len = b; continue :sw .{ .ret = v }; },
                    .step => continue :sw try runtime.start(b, e), // a native frame: the arguments stay on vs
                },
                else => return fail(str("ToyLisp: {f} is not a function", .{f})),
            }
        },
    }
}

// Iterative parser: `open` holds where each unfinished list starts in `done` (null: a pending quote).
var src: []const u8 = ""; var pos: usize = 0; const space = " \t\n\r"; const unexpected = "ToyLisp: Syntax error, unexpected closing parenthesis";
fn peek() u8 { return if (pos < src.len) src[pos] else 0; }
fn skip() void { while (true) { pos = std.mem.indexOfNonePos(u8, src, pos, space) orelse src.len; if (peek() != ';') return; pos = std.mem.indexOfAnyPos(u8, src, pos, "\n\x00") orelse src.len; } }
fn atom() V { // symbols and literals are permanent; a 0 byte ends the source
    const lit = peek() == '"'; const s = pos + @intFromBool(lit);
    pos = std.mem.indexOfAnyPos(u8, src, s, if (lit) "\"\x00" else space ++ "\x00()';\"") orelse src.len;
    const t = src[s..pos]; if (lit and peek() == '"') pos += 1;
    if (!lit and std.mem.indexOfAny(u8, t, "0123456789") != null) if (std.fmt.parseFloat(f64, t)) |d| return .{ .n = d } else |_| {};
    return if (lit) .{ .lit = runtime.mkstr(t, true) } else .{ .s = runtime.mkstr(t, true) };
}
pub fn parse(text: []const u8) E!V {
    src = text; pos = 0;
    var done: std.ArrayList(V) = .empty; defer done.deinit(std.heap.c_allocator); var open: std.ArrayList(?usize) = .empty; defer open.deinit(std.heap.c_allocator);
    while (open.items.len > 0 or done.items.len == 0) {
        skip();
        var d: V = switch (peek()) {
            0 => return fail(str("ToyLisp: Syntax error, unbalanced expression", .{})),
            '(', '\'' => |c| { pos += 1; gc.push(?usize, &open, if (c == '(') done.items.len else null); continue; },
            ')' => blk: {
                pos += 1; if (open.items.len == 0 or open.getLast() == null) return fail(str(unexpected, .{}));
                const xs = done.items[open.pop().?.?..]; done.items.len -= xs.len; break :blk list(xs, xs.len);
            },
            else => atom(),
        };
        while (open.items.len > 0 and open.getLast() == null) : (_ = open.pop()) d = list(&.{ .{ .s = runtime.mkstr("quote", true) }, d }, 2);
        gc.push(V, &done, d);
    }
    skip(); if (peek() != 0) return fail(str(unexpected, .{}));
    return done.items[0];
}
