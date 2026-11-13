// The primitives: + - * / < > eq? car cons list at vset! ... Each is a plain native, all built from one function (`prim`)
// that is specialised per operation at compile time. `fast` and `fast1` are the same operations for the common case (numbers,
// or a list and an index) that needs no allocation and cannot fail: the evaluator and the bytecode use them to compute a
// primitive call in place.
const std = @import("std");
const rt = @import("runtime.zig");
const V = rt.V;
const E = rt.E;
const arg = rt.arg;
const items = rt.items;
const num = rt.num;
const truthy = rt.truthy;
const str = rt.str;
const fail = rt.fail;
const list = rt.list;

pub const Op = enum { @"+", @"-", @"*", @"/", mod, @">", @"<", @">=", @"<=", @"&&", @"||", @"eq?", car, cdr, len, cons, list, @"error", at, @"vset!", not, min, max, exp, log, sqrt, cos, floor, abs };

fn binop(op: Op, x: V, y: V) V {
    const a = num(x);
    const b = num(y);
    return switch (op) {
        .@"+" => if (x.is(.s) or x.is(.lit) or y.is(.s) or y.is(.lit)) str("{f}{f}", .{ x, y }) else V.num(a + b),
        .@"-" => V.num(a - b),
        .@"*" => V.num(a * b),
        .@"/" => V.num(a / b),
        .mod => V.num(a - b * @floor(a / b)),
        .@">" => V.boolean(a > b),
        .@"<" => V.boolean(a < b),
        .@">=" => V.boolean(a >= b),
        .@"<=" => V.boolean(a <= b),
        .@"&&" => if (truthy(x)) y else x,
        else => if (truthy(x)) x else y,
    };
}

/// One native per op, so each is specialised at compile time.
fn primFor(comptime op: Op) *const fn (*rt.Fn, []const V) E!V {
    return struct {
        fn f(_: *rt.Fn, a: []const V) E!V {
            return prim(op, a);
        }
    }.f;
}

inline fn prim(comptime op: Op, a: []const V) E!V {
    const x = arg(a, 0);
    if (comptime switch (op) {
        .@"+", .@"-", .@"*", .@"/", .mod, .@">", .@"<", .@">=", .@"<=", .@"&&", .@"||" => true,
        else => false,
    }) { // arithmetic, comparison, && and ||: fold left
        if (a.len == 2 and a[0].isNum() and a[1].isNum()) {
            const p = a[0].asNum();
            const q = a[1].asNum();
            switch (op) {
                .@"+" => return V.num(p + q),
                .@"-" => return V.num(p - q),
                .@"*" => return V.num(p * q),
                .@"/" => return V.num(p / q),
                .mod => return V.num(p - q * @floor(p / q)),
                .@">" => return V.boolean(p > q),
                .@"<" => return V.boolean(p < q),
                .@">=" => return V.boolean(p >= q),
                .@"<=" => return V.boolean(p <= q),
                else => {},
            }
        }
        var r = x;
        for (a[@min(1, a.len)..]) |y| r = binop(op, r, y);
        return r;
    }
    if (comptime switch (op) {
        .exp, .log, .sqrt, .cos, .floor, .abs => true,
        else => false,
    }) { // math: one number in, one number out
        const n = num(x);
        return V.num(switch (op) {
            .exp => @exp(n),
            .log => @log(n),
            .sqrt => @sqrt(n),
            .cos => @cos(n),
            .abs => @abs(n),
            else => @floor(n),
        });
    }
    if (op == .not) return V.boolean(!truthy(x));
    if (op == .min or op == .max) { // several numbers or one list, like Python's
        const l = if (a.len == 1 and x.is(.l)) items(x) else a;
        if (l.len == 0) return fail(str("TinyLisp: {s} of nothing", .{@tagName(op)}));
        var r = l[0];
        for (l[1..]) |y| if (if (op == .min) num(y) < num(r) else num(y) > num(r)) {
            r = y;
        };
        return r;
    }
    const l = items(if (op == .cons) arg(a, 1) else x);
    switch (op) {
        .car => return arg(l, 0),
        .cdr => return list(l[@min(1, l.len)..], l.len -| 1),
        .len => return V.num(@floatFromInt(l.len)),
        .at => {
            const i = num(arg(a, 1));
            return if (i >= 0 and i < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(i)] else .nil;
        },
        .list => return list(a, a.len),
        .@"error" => return fail(x),
        .@"vset!" => { // (vset! list i v): store v at index i of the list itself (nothing needs a write barrier)
            const i = num(arg(a, 1));
            if (!(i >= 0 and i < @as(f64, @floatFromInt(l.len)))) return fail(str("TinyLisp: vset! index out of range", .{}));
            l[@intFromFloat(i)] = arg(a, 2);
            return arg(a, 2);
        },
        .@"eq?" => return V.boolean(for (a) |y| (if (!rt.eq(y, x)) break false) else true),
        .cons => {
            const r = list(&.{x}, l.len + 1);
            for (l, r.asList().items()[1..]) |y, *z| z.* = y;
            return r;
        },
        else => unreachable,
    }
}

/// Is v the native vset!? (tier 2 has an instruction for it)
pub fn isVset(v: V) bool {
    return v.is(.f) and v.asFn().f == .plain and v.asFn().f.plain == primFor(.@"vset!");
}

pub fn primOp(v: V) ?Op {
    if (!v.is(.f) or v.asFn().f != .plain) return null;
    inline for (comptime std.enums.values(Op)) |op| {
        if (v.asFn().f.plain == primFor(op)) return switch (op) {
            .@"+", .@"-", .@"*", .@"/", .mod, .@">", .@"<", .@">=", .@"<=", .@"eq?", .at, .not, .abs, .floor, .sqrt, .exp, .log, .cos => op,
            else => null,
        };
    }
    return null;
}

pub fn unary(op: Op) bool {
    return switch (op) {
        .not, .abs, .floor, .sqrt, .exp, .log, .cos => true,
        else => false,
    };
}

/// The value of (op x) for a one-operand primitive, null if x is not a number (not: always).
pub fn fast1(op: Op, x: V) ?V {
    if (op == .not) return V.boolean(!truthy(x));
    if (!x.isNum()) return null;
    const p = x.asNum();
    return V.num(switch (op) {
        .abs => @abs(p),
        .floor => @floor(p),
        .sqrt => @sqrt(p),
        .exp => @exp(p),
        .log => @log(p),
        else => @cos(p),
    });
}

/// The value of (op x y) when it needs no allocation and no error, else null.
pub fn fast(op: Op, x: V, y: V) ?V {
    if (op == .@"eq?") return V.boolean(rt.eq(x, y));
    if (!y.isNum()) return null;
    const q = y.asNum();
    if (op == .at) {
        if (!x.is(.l)) return null;
        const l = x.asList().items();
        return if (q >= 0 and q < @as(f64, @floatFromInt(l.len))) l[@intFromFloat(q)] else null;
    }
    if (!x.isNum()) return null;
    const p = x.asNum();
    return switch (op) {
        .@"+" => V.num(p + q),
        .@"-" => V.num(p - q),
        .@"*" => V.num(p * q),
        .@"/" => V.num(p / q),
        .mod => V.num(p - q * @floor(p / q)),
        .@">" => V.boolean(p > q),
        .@"<" => V.boolean(p < q),
        .@">=" => V.boolean(p >= q),
        .@"<=" => V.boolean(p <= q),
        else => null,
    };
}

/// Define every primitive in the root scope, under its own name.
pub fn install(e: *rt.Env) void {
    inline for (comptime std.enums.values(Op)) |op| rt.set(e, @tagName(op), V.fnOf(rt.nf(.{ .plain = primFor(op) }, .nil, .nil)));
}
