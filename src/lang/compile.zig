// The tree tier's compiler: the AST (parser.zig) becomes nodes, which eval.zig runs and vm/compiler.zig compiles further.
// This file and eval.zig need each other: expanding macros runs Lisp functions (`expand` calls eval.exec), and the evaluator
// compiles a node the first time it meets it (`force`).
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const node = @import("../runtime/node.zig");
const machine = @import("../runtime/machine.zig");
const primitives = @import("../runtime/primitives.zig");
const eval = @import("eval.zig");
const V = value.V;
const Node = node.Node;

// The AST becomes nodes (node.Node) once, lazily: a node is compiled when first evaluated, so macros see code in the order it
// runs. Every macro/* runs once per node; a new or redefined one (scope.epoch) recompiles all nodes. Nodes and symbols are
// permanent; their AST is pinned.

/// While a macro runs, code is not expanded (so expansion nests one level).
pub var in_macro = false;

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

/// A node that is not compiled yet.
pub fn stub(v: V) *Node {
    const n = &make(Node, 1)[0];
    n.* = .{ .ast = gc.pin(v) };
    return n;
}

/// n nodes for the items of a, nil for missing ones.
fn kids(a: []const V, n: usize) []const *Node {
    const c = make(*Node, n);
    for (c, 0..) |*x, i| x.* = stub(value.arg(a, i));
    return c;
}

/// The stamp of up-to-date code; 0 means not compiled yet.
pub fn current() u32 {
    return scope.epoch *% 2 +% @intFromBool(in_macro) +% 1;
}

/// Every macro/* over x in turn; one that returns a false value leaves x as it was.
fn expand(x: V) value.E!V {
    in_macro = true;
    defer in_macro = false;
    var y = x;
    for (scope.macros.items) |macro| {
        const b = machine.vs.items.len;
        defer machine.vs.items.len = b;
        gc.push(V, &machine.vs, macro.*);
        gc.push(V, &machine.vs, y);
        const z = try eval.exec(.{ .apply = b }, scope.root);
        if (value.truthy(z)) y = z;
    }
    return y;
}

const Form = enum { quote, lambda, @"if", begin, define, @"set!", @"&&", @"||", apply }; // apply: anything else

/// The code of a list: a special form by its head, or a call.
fn form(a: []const V) value.E!node.Code {
    if (a.len == 0) return value.fail(value.str("TinyLisp: cannot evaluate an empty list", .{}));
    const head = if (a[0].is(.s)) std.meta.stringToEnum(Form, std.mem.span(a[0].asStr())) orelse .apply else .apply;
    switch (head) {
        .quote => return .{ .val = value.arg(a, 1) },
        .lambda => {
            const ps = value.items(value.arg(a, 1));
            const params = make(node.Key, ps.len);
            const proto = &make(node.Proto, 1)[0];
            proto.* = .{ .params = params[0..0], .body = stub(value.arg(a, 2)) };
            var n: usize = 0;
            for (ps) |p| {
                if (p.is(.s) and std.mem.eql(u8, std.mem.span(p.asStr()), "&")) { // (a b & rest): rest takes the extra arguments
                    proto.rest = true;
                    continue;
                }
                const sym = intern(p);
                if (sym.inlined and !sym.local) scope.epoch +%= 1;
                sym.local = true;
                params[n] = sym.key;
                n += 1;
                proto.params = params[0..n];
            }
            return .{ .lambda = proto };
        },
        .@"if" => return .{ .@"if" = kids(a[1..], 3) },
        .begin => return .{ .begin = kids(a[1..], @max(a.len - 1, 1)) }, // (begin) is nil
        .@"&&" => return .{ .@"&&" = kids(a[1..], @max(a.len - 1, 1)) }, // short-circuit
        .@"||" => return .{ .@"||" = kids(a[1..], @max(a.len - 1, 1)) },
        .define, .@"set!" => {
            const d = &make(node.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = stub(value.arg(a, 2)), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return call(a, kids(a, a.len)),
    }
}

/// The code of the call a (c: its items). Two kinds of call are recognised by their head, while it is a global no scope binds:
/// - the native each or map with a lambda as the last operand: the lambda gets a guard, so making it captures nothing (scope.lambda);
/// - a primitive that `primitives.fast` knows, with one or two operands: a Prim node, computed in place (`inplace` in eval.zig).
fn call(a: []const V, c: []const *Node) node.Code {
    if (!a[0].is(.s)) return .{ .call = c };
    const sym = intern(a[0]);
    const g = scope.globalOf(sym) orelse return .{ .call = c };
    const last = value.items(a[a.len - 1]);
    if (a.len >= 3 and last.len > 0 and last[0].is(.s) and std.mem.eql(u8, std.mem.span(last[0].asStr()), "lambda")) {
        if (g.* == node.each_v or g.* == node.map_v) {
            c[c.len - 1].guard = &make(node.Guard, 1)[0];
            c[c.len - 1].guard.?.* = .{ .sym = sym, .g = g, .f = gc.pin(g.*) };
        }
    }
    if (a.len == 2 or a.len == 3) if (primitives.primOp(g.*)) |op| if ((a.len == 2) == primitives.unary(op)) {
        const p = &make(node.Prim, 1)[0];
        sym.inlined = true;
        p.* = .{ .op = op, .sym = sym, .g = g, .f = gc.pin(g.*), .c = c };
        return .{ .prim = p };
    };
    return .{ .call = c };
}

/// Expand macros over n's AST, then build its code unless they changed nothing.
pub fn force(n: *Node) value.E!void {
    const x = if (in_macro or value.ptr(n.ast) == null) n.ast else try expand(n.ast);
    if (n.code == .raw or x != n.src) {
        n.code = switch (x.tag()) {
            .s => .{ .ref = .{ .sym = intern(x) } },
            .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
            .l => try form(x.asList().items()),
            else => .{ .val = x },
        };
        if (n.code == .lambda) n.code.lambda.guard = n.guard;
        n.src = gc.pin(x);
    }
    n.stamp = current();
}
