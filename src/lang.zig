// zig fmt: off
const std = @import("std"); const gc = @import("gc.zig"); const runtime = @import("runtime.zig");

// Public language API; runtime owns values, parsing, scopes, and primitives.
pub const E = runtime.E; pub const V = runtime.V; pub const Lst = runtime.Lst;
pub const Fn = runtime.Fn; pub const Lam = runtime.Lam; pub const Env = runtime.Env; pub const Var = runtime.Var;
pub const ptr = runtime.ptr; pub const rv = runtime.rv; pub const arg = runtime.arg; pub const items = runtime.items;
pub const str = runtime.str; pub const list = runtime.list; pub const nf = runtime.nf; pub const num = runtime.num;
pub const parse = runtime.parse; pub const set = runtime.set; pub const topLevel = runtime.topLevel;
const name = runtime.name; const lookup = runtime.lookup; const bind = runtime.bind;
const fail = runtime.fail; const truthy = runtime.truthy; const gpa = std.heap.c_allocator;
pub var out: *std.Io.Writer = undefined;
pub var errv: V = .nil;

// Pending work lives in heap frames: Lisp recursion never grows the native stack.
const Form = enum { quote, lambda, @"if", begin, define, @"set!", apply }; // apply: anything else
const K = struct { kind: Form, i: usize, base: usize, mark: usize, l: []V, e: *Env };
var ks: std.ArrayList(K) = .empty; // frame stack
var vs: std.ArrayList(V) = .empty; // operand stack: evaluated function + arguments
var depth: usize = 0; // native callbacks re-enter eval on the native stack
var in_macro = false;

// Calls from natives share eval's region discipline and callback depth guard.
pub fn call(f: V, a: []const V) E!V {
    const m = gc.mark();
    return switch (f) { .f => |n| n.f(n, a), .lam => |l| gc.sweepKeep(m, try eval(l.body, bind(l, a))),
        else => fail(str("ToyLisp: {f} is not a function", .{f})), };
}

// Expand each node, evaluate it, then feed its value through pending frames.
pub fn eval(node: V, env: *Env) E!V {
    var m0 = gc.mark(); const base, const vbase = .{ ks.items.len, vs.items.len };
    var x = node; var e = env;
    errdefer ks.items.len, vs.items.len = .{ base, vbase }; // drop the frames of an aborted evaluation
    depth += 1; defer depth -= 1;
    if (depth > 8000) return fail(str("ToyLisp: recursion too deep (over 8000 nested calls made by native functions)", .{}));
    ev: while (true) {
        if (!in_macro) { // every macro/* in the root scope sees every node before it's evaluated
            in_macro = true; defer in_macro = false;
            for (runtime.macros.items) |m| { const y = try call(m.*, &.{x}); if (truthy(y)) x = y; }
        }
        var v: V = switch (x) {
            .s => |s| if (lookup(e, s)) |p| p.* else .nil,
            .lit => |s| .{ .s = s },
            .l => |l| blk: {
                const a = l.a; if (a.len == 0) return fail(str("ToyLisp: cannot evaluate an empty list", .{}));
                const kind = if (a[0] == .s) std.meta.stringToEnum(Form, std.mem.span(a[0].s)) orelse .apply else .apply;
                if (kind == .quote) break :blk arg(a, 1);
                if (kind == .lambda) {
                    gc.ret(e);
                    break :blk .{ .lam = gc.new(Lam, 0, .lam, .{ .params = rv(arg(a, 1)), .body = rv(arg(a, 2)), .env = e }) };
                }
                const i: usize = if (kind == .apply) 0 else if (kind == .define or kind == .@"set!") 2 else 1;
                if (kind != .begin or a.len > 2) gc.push(K, &ks, .{ .kind = kind, .i = i, .base = vs.items.len, .mark = gc.mark(), .l = a, .e = e });
                x = arg(a, i); continue :ev;
            },
            else => x,
        };
        while (true) { // hand v to the innermost frame
            if (ks.items.len == base) return gc.sweepKeep(m0, v);
            const k = &ks.items[ks.items.len - 1];
            v = gc.sweepKeep(k.mark, v);
            const a = k.l; e = k.e;
            switch (k.kind) {
                .@"if" => { // tail position: no frame
                    ks.items.len -= 1;
                    x = if (truthy(v)) arg(a, 2) else arg(a, 3); continue :ev;
                },
                .begin => {
                    k.i += 1; x = a[k.i];
                    if (k.i == a.len - 1) ks.items.len -= 1 else k.mark = gc.mark();
                    continue :ev;
                },
                .define, .@"set!" => {
                    ks.items.len -= 1; const s = name(a[1]);
                    if (k.kind == .define) set(e, s, v) else if (lookup(e, s)) |p| { gc.rel(ptr(p.*)); p.* = rv(v); }
                },
                else => { // apply
                    if (k.i == 0 and v == .nil) return fail(str("ToyLisp: Function {f} is not defined", .{a[0]}));
                    gc.push(V, &vs, v); k.i += 1;
                    if (k.i < a.len) { k.mark = gc.mark(); x = a[k.i]; continue :ev; }
                    const f = vs.items[k.base]; const args = vs.items[k.base + 1 ..];
                    ks.items.len -= 1; vs.items.len = k.base; // args stays readable until vs grows again
                    if (f != .lam) { // copy: natives may re-enter eval and grow vs
                        var small: [16]V = undefined;
                        const copy = if (args.len <= small.len) small[0..args.len] else gpa.dupe(V, args) catch gc.oom();
                        defer if (args.len > small.len) gpa.free(copy);
                        @memcpy(copy, args); v = try call(f, copy); continue;
                    }
                    e = bind(f.lam, args); x = f.lam.body; // tail call: only x and e stay live
                    const mk = if (ks.items.len > base) &ks.items[ks.items.len - 1].mark else &m0;
                    mk.* = gc.resweep(mk.*, x, e); continue :ev;
                },
            }
        }
    }
}
