// The typed AST: the (macro-expanded, see expand.zig) AST of a top-level form becomes nodes, once, all of it at the time the form is
// compiled. vm/compiler.zig turns the nodes into bytecode, a function at a time, when the function is first called.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const node = @import("../runtime/node.zig");
const V = value.V;
const Node = node.Node;

/// The deepest nesting of one form that is compiled. The compiler's own recursion (here, in vm/scan.zig and vm/compiler.zig) follows
/// the nesting of the code, so it is bounded; the limit leaves the native stack room for that (a frame is a few hundred bytes).
/// Deep *data* (quote) and deep run-time recursion are not code and have no limit.
pub const max_depth = 5000;

const make = node.make;
var interned: std.StringHashMapUnmanaged(*node.Sym) = .empty;

/// The symbol of a name: equal names are the same symbol, so scopes compare keys by address.
fn intern(v: V) *node.Sym {
    const name = std.mem.span(if (v.is(.s)) v.asStr() else value.str("{f}", .{v}).asStr());
    const entry = interned.getOrPut(value.gpa, name) catch gc.oom();
    if (!entry.found_existing) { // the table's key is the symbol's own name
        entry.value_ptr.* = &make(node.Sym, 1)[0];
        entry.value_ptr.*.* = .{ .key = value.mkstr(name, true) };
        entry.key_ptr.* = std.mem.span(entry.value_ptr.*.key);
    }
    return entry.value_ptr.*;
}

/// The nodes of a top-level form, expanded already. The AST is pinned for good: nodes and the bytecode refer to it.
pub fn top(x: V) value.E!*Node {
    return build(gc.pin(x), 0);
}

fn build(x: V, depth: usize) value.E!*Node {
    if (depth > max_depth) return value.fail(value.str("TinyLisp: expression is nested too deeply to compile (limit {d})", .{max_depth}));
    const n = &make(Node, 1)[0];
    const code: node.Code = switch (x.tag()) {
        .s => .{ .ref = .{ .sym = intern(x) } },
        .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
        .l => try form(x.asList().items(), depth),
        else => .{ .val = x },
    };
    n.* = .{ .ast = x, .code = code };
    return n;
}

/// n nodes for the items of a, nil for missing ones.
fn kids(a: []const V, n: usize, depth: usize) value.E![]const *Node {
    const c = make(*Node, n);
    for (c, 0..) |*x, i| x.* = try build(value.arg(a, i), depth + 1);
    return c;
}

const Form = enum { quote, lambda, @"if", begin, define, @"set!", @"&&", @"||", apply }; // apply: anything else

/// Is name a special form (or defmacro, which the expander itself understands)? No macro may take such a name.
pub fn isSpecial(name: []const u8) bool {
    return std.mem.eql(u8, name, "defmacro") or (std.meta.stringToEnum(Form, name) orelse .apply) != .apply;
}

/// The code of a list: a special form by its head, or a call.
fn form(a: []const V, depth: usize) value.E!node.Code {
    if (a.len == 0) return .empty;
    const head = if (a[0].is(.s)) std.meta.stringToEnum(Form, std.mem.span(a[0].asStr())) orelse .apply else .apply;
    switch (head) {
        .quote => return .{ .val = value.arg(a, 1) },
        .lambda => {
            const ps = value.items(value.arg(a, 1));
            const params = make(node.Key, ps.len);
            const proto = &make(node.Proto, 1)[0];
            proto.* = .{ .params = params[0..0], .body = try build(value.arg(a, 2), depth + 1) };
            var n: usize = 0;
            for (ps) |p| {
                if (p.is(.s) and std.mem.eql(u8, std.mem.span(p.asStr()), "&")) { // (a b & rest): rest takes the extra arguments
                    proto.rest = true;
                    continue;
                }
                const sym = intern(p);
                if (sym.inlined and !sym.local) scope.epoch +%= 1; // code compiled with the global (a primitive, each...) is out of date
                sym.local = true;
                params[n] = sym.key;
                n += 1;
            }
            proto.params = params[0..n];
            return .{ .lambda = proto };
        },
        .@"if" => return .{ .@"if" = try kids(a[1..], 3, depth) },
        .begin => return .{ .begin = try kids(a[1..], @max(a.len - 1, 1), depth) }, // (begin) is nil
        .@"&&" => return .{ .@"&&" = try kids(a[1..], @max(a.len - 1, 1), depth) }, // short-circuit
        .@"||" => return .{ .@"||" = try kids(a[1..], @max(a.len - 1, 1), depth) },
        .define, .@"set!" => {
            const d = &make(node.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = try build(value.arg(a, 2), depth + 1), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return .{ .call = try kids(a, a.len, depth) },
    }
}
