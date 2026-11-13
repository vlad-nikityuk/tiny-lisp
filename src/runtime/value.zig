// Values: V, the objects it can point to, how to build and test them, the printer, and the value of the error being raised.
// The types of the other parts appear here only as what a value points to (a closure's code and scope, a native's frame).
const std = @import("std");
const gc = @import("gc.zig");
const machine = @import("machine.zig");
const Env = @import("scope.zig").Env;
const Proto = @import("node.zig").Proto;
const Frame = machine.Frame;
const Go = machine.Go;

pub const E = error{Lisp}; // the error value itself is in `errv`
/// The value of the Lisp error being raised.
pub var errv: V = .nil;
/// A value in 8 bytes (NaN boxing): a number is its own double bits, everything else lives in the quiet-NaN space with a
/// 3-bit tag in bits 48-50 and a 48-bit pointer or flag as payload. Numbers that are NaN are stored as one canonical NaN.
pub const V = enum(u64) {
    _,
    pub const Tag = enum { n, nil, b, s, lit, l, f, lam }; // s: symbol or runtime string, lit: string literal from source
    const BOX: u64 = 0xFFF8_0000_0000_0000;
    const PAYLOAD: u64 = 0x0000_FFFF_FFFF_FFFF;
    pub const nil: V = @fromBackingInt(@intCast(BOX | 1 << 48));

    inline fn box(t: u64, payload: u64) V {
        return @fromBackingInt(@intCast(BOX | t << 48 | payload));
    }
    inline fn bits(v: V) u64 {
        return @backingInt(v);
    }
    inline fn addr(v: V) usize {
        return @intCast(v.bits() & PAYLOAD);
    }
    pub inline fn num(x: f64) V {
        return if (x != x) @fromBackingInt(@intCast(0x7FF8_0000_0000_0000)) else @fromBackingInt(@intCast(@as(u64, @bitCast(x))));
    }
    pub inline fn boolean(x: bool) V {
        return box(2, @intFromBool(x));
    }
    pub inline fn string(p: [*:0]const u8) V {
        return box(3, @intFromPtr(p));
    }
    pub inline fn literal(p: [*:0]const u8) V {
        return box(4, @intFromPtr(p));
    }
    pub inline fn listOf(p: *Lst) V {
        return box(5, @intFromPtr(p));
    }
    pub inline fn fnOf(p: *Fn) V {
        return box(6, @intFromPtr(p));
    }
    pub inline fn lamOf(p: *Lam) V {
        return box(7, @intFromPtr(p));
    }
    pub inline fn tag(v: V) Tag {
        if (v.bits() >> 51 != 0x1FFF) return .n;
        return switch (v.bits() >> 48 & 7) {
            1 => .nil,
            2 => .b,
            3 => .s,
            4 => .lit,
            5 => .l,
            6 => .f,
            7 => .lam,
            else => .n,
        };
    }
    pub inline fn isNum(v: V) bool {
        return v.bits() >> 51 != 0x1FFF;
    }
    pub inline fn is(v: V, t: Tag) bool {
        return v.tag() == t;
    }
    pub inline fn asNum(v: V) f64 {
        return @bitCast(v.bits());
    }
    pub inline fn asBool(v: V) bool {
        return v.bits() & 1 != 0;
    }
    pub inline fn asStr(v: V) [*:0]const u8 { // for s and lit
        return @ptrFromInt(v.addr());
    }
    pub inline fn asList(v: V) *Lst {
        return @ptrFromInt(v.addr());
    }
    pub inline fn asFn(v: V) *Fn {
        return @ptrFromInt(v.addr());
    }
    pub inline fn asLam(v: V) *Lam {
        return @ptrFromInt(v.addr());
    }

    /// Iterative, so nested lists can't overflow the native stack.
    pub fn format(top: V, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var todo: std.ArrayList(?V) = .empty; // null: a list's closing parenthesis
        defer todo.deinit(std.heap.c_allocator);
        gc.push(?V, &todo, top);
        while (todo.pop()) |item| {
            if (item) |v| switch (v.tag()) {
                .nil => try w.writeAll("nil"),
                .b => try w.writeAll(if (v.asBool()) "#t" else "#f"),
                .n => {
                    const n = v.asNum();
                    if (n == @trunc(n) and @abs(n) < 1e18) try w.print("{d}", .{@as(i64, @intFromFloat(n))}) else try w.print("{d}", .{n});
                },
                .s => try w.writeAll(std.mem.span(v.asStr())),
                .lit => try w.print("\"{s}\"", .{v.asStr()}),
                .l => {
                    try w.writeByte('(');
                    gc.push(?V, &todo, null);
                    var it = std.mem.reverseIterator(v.asList().items());
                    while (it.next()) |x| gc.push(?V, &todo, x);
                    continue;
                },
                .f, .lam => try w.writeAll("<function>"),
            } else try w.writeByte(')');
            if (todo.getLastOrNull()) |next| if (next != null) try w.writeByte(' '); // more items of the same list
        }
    }
};
/// A list: its items are stored inline, right after the length.
pub const Lst = struct {
    len: usize,
    pub inline fn items(self: *Lst) []V {
        return gc.after(V, self)[0..self.len];
    }
};
/// A native function. d0, d1: its own data (the function and the fixed arguments of a partial, say); i: the trampoline's state.
pub const Fn = struct { f: Native, d0: V, d1: V, i: usize = 0 };
/// plain: computes its value directly. step: calls back into Lisp, so it runs as a frame of the machine: it is
/// invoked with null first, then with each callback's value, and says what the machine does next.
pub const Native = union(enum) { plain: *const fn (*Fn, []const V) E!V, step: *const fn (*Fn, *Frame, ?V) E!Go };
/// A closure: code and the scope it was made in.
pub const Lam = struct { proto: *Proto, env: *Env };

pub const gpa = std.heap.c_allocator;

// constructors and tests
// ----------------------------------------------------------------
/// The managed object a value points to, if any (for the collector).
pub fn ptr(v: V) ?*anyopaque {
    return switch (v.tag()) {
        .nil, .b, .n => null,
        .s, .lit => @ptrCast(@constCast(v.asStr())),
        .l => v.asList(),
        .f => v.asFn(),
        .lam => v.asLam(),
    };
}

pub fn arg(a: []const V, i: usize) V {
    return if (i < a.len) a[i] else .nil;
}

pub fn items(v: V) []V {
    return if (v.is(.l)) v.asList().items() else &.{};
}

/// A copy of s as a managed (or permanent) string.
pub fn mkstr(s: []const u8, perm: bool) [*:0]u8 {
    const t: [*]u8 = @ptrCast(if (perm) gc.perm(s.len + 1) else gc.alloc(s.len + 1, .str));
    @memcpy(t[0..s.len], s);
    t[s.len] = 0;
    return @ptrCast(t);
}

pub fn str(comptime f: []const u8, args: anytype) V {
    const m = std.fmt.allocPrint(gpa, f, args) catch gc.oom();
    defer gpa.free(m);
    return V.string(mkstr(m, false));
}

/// Raise the Lisp error e.
pub fn fail(e: V) E {
    errv = e;
    return error.Lisp;
}

/// The error of calling a name (as written in the source) that has no value.
pub fn undefinedFunction(name: V) E {
    return fail(str("TinyLisp: Function {f} is not defined", .{name}));
}

/// A list of n items: a, then nils.
pub fn list(a: []const V, n: usize) V {
    const l = gc.new(Lst, n * @sizeOf(V), .list, .{ .len = n });
    for (l.items(), 0..) |*x, i| x.* = arg(a, i);
    return V.listOf(l);
}

/// A native function value's object.
pub fn nf(f: Native, d0: V, d1: V) *Fn {
    return gc.new(Fn, 0, .func, .{ .f = f, .d0 = d0, .d1 = d1 });
}

pub fn truthy(v: V) bool {
    return switch (v.tag()) {
        .nil => false,
        .b => v.asBool(),
        .n => v.asNum() != 0 and v.asNum() == v.asNum(),
        .s => v.asStr()[0] != 0,
        else => true,
    };
}

fn isNil(v: V) bool {
    return v == V.nil or (v.is(.l) and v.asList().len == 0);
}

pub fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

pub fn eq(a: V, b: V) bool {
    if (isNil(a) or isNil(b)) return isNil(a) and isNil(b);
    if ((a.is(.s) and b.is(.s)) or (a.is(.lit) and b.is(.lit))) return streq(a.asStr(), b.asStr());
    if (a.isNum() and b.isNum()) return a.asNum() == b.asNum();
    return a == b;
}

/// The number a value counts as in arithmetic.
pub fn num(v: V) f64 {
    return switch (v.tag()) {
        .n => v.asNum(),
        .b => @floatFromInt(@intFromBool(v.asBool())),
        .nil => 0,
        else => std.math.nan(f64),
    };
}
