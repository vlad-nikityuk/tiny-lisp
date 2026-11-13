// The tree tier's compiler: the AST (parser.zig) becomes nodes, which eval.zig runs and vm/compiler.zig compiles further.
// This file and eval.zig need each other: expanding macros runs Lisp functions (`expand` calls eval.exec), and the evaluator
// compiles a node the first time it meets it (`force`).
const std = @import("std");
const gc = @import("../runtime/gc.zig");
const rt = @import("../runtime/runtime.zig");
const scope = @import("../runtime/scope.zig");
const prims = @import("../runtime/primitives.zig");
const eval = @import("eval.zig");
const machine = @import("../runtime/machine.zig");
const V = rt.V;
const Node = rt.Node;

// The AST becomes nodes (rt.Node) once, lazily: a node is compiled when first evaluated, so macros see code in the order it
// runs. Every macro/* runs once per node; a new or redefined one (scope.epoch) recompiles all nodes. Nodes and symbols are
// permanent; their AST is pinned.

/// While a macro runs, code is not expanded (so expansion nests one level).
pub var in_macro = false;

const make = rt.make;
var interned: std.StringHashMapUnmanaged(*rt.Sym) = .empty;

/// The symbol of a name: equal names are the same symbol, so scopes compare keys by address.
fn intern(v: V) *rt.Sym {
    const name = std.mem.span(if (v.is(.s)) v.asStr() else rt.str("{f}", .{v}).asStr());
    const entry = interned.getOrPut(rt.gpa, name) catch gc.oom();
    if (!entry.found_existing) { // the table's key is the symbol's own name
        entry.value_ptr.* = &make(rt.Sym, 1)[0];
        entry.value_ptr.*.* = .{ .key = rt.mkstr(name, true) };
        entry.key_ptr.* = std.mem.span(entry.value_ptr.*.key);
    }
    return entry.value_ptr.*;
}

/// A node that is not compiled yet.
pub fn stub(v: V) *Node {
    const n = &make(Node, 1)[0];
    n.* = .{ .ast = rt.pin(v) };
    return n;
}

/// n nodes for the items of a, nil for missing ones.
fn kids(a: []const V, n: usize) []const *Node {
    const c = make(*Node, n);
    for (c, 0..) |*x, i| x.* = stub(rt.arg(a, i));
    return c;
}

/// The stamp of up-to-date code; 0 means not compiled yet.
pub fn current() u32 {
    return scope.epoch *% 2 +% @intFromBool(in_macro) +% 1;
}

/// Every macro/* over x in turn; one that returns a false value leaves x as it was.
fn expand(x: V) rt.E!V {
    in_macro = true;
    defer in_macro = false;
    var y = x;
    for (scope.macros.items) |macro| {
        const b = machine.vs.items.len;
        defer machine.vs.items.len = b;
        gc.push(V, &machine.vs, macro.*);
        gc.push(V, &machine.vs, y);
        const z = try eval.exec(.{ .apply = b }, scope.root);
        if (rt.truthy(z)) y = z;
    }
    return y;
}

const Form = enum { quote, lambda, @"if", begin, define, @"set!", @"&&", @"||", apply }; // apply: anything else

/// The code of a list: a special form by its head, or a call.
fn form(a: []const V) rt.E!rt.Code {
    if (a.len == 0) return rt.fail(rt.str("TinyLisp: cannot evaluate an empty list", .{}));
    const head = if (a[0].is(.s)) std.meta.stringToEnum(Form, std.mem.span(a[0].asStr())) orelse .apply else .apply;
    switch (head) {
        .quote => return .{ .val = rt.arg(a, 1) },
        .lambda => {
            const ps = rt.items(rt.arg(a, 1));
            const params = make(rt.Key, ps.len);
            const proto = &make(rt.Proto, 1)[0];
            proto.* = .{ .params = params[0..0], .body = stub(rt.arg(a, 2)) };
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
            const d = &make(rt.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = stub(rt.arg(a, 2)), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return call(a, kids(a, a.len)),
    }
}

/// The code of the call a (c: its items). Two kinds of call are recognised by their head, while it is a global no scope binds:
/// - the native each or map with a lambda as the last operand: the lambda gets a guard, so making it captures nothing (scope.lambda);
/// - a primitive that `primitives.fast` knows, with one or two operands: a Prim node, computed in place (`inplace` below).
fn call(a: []const V, c: []const *Node) rt.Code {
    if (!a[0].is(.s)) return .{ .call = c };
    const sym = intern(a[0]);
    const g = scope.globalOf(sym) orelse return .{ .call = c };
    const last = rt.items(a[a.len - 1]);
    if (a.len >= 3 and last.len > 0 and last[0].is(.s) and std.mem.eql(u8, std.mem.span(last[0].asStr()), "lambda")) {
        if (g.* == rt.each_v or g.* == rt.map_v) {
            c[c.len - 1].guard = &make(rt.Guard, 1)[0];
            c[c.len - 1].guard.?.* = .{ .sym = sym, .g = g, .f = rt.pin(g.*) };
        }
    }
    if (a.len == 2 or a.len == 3) if (prims.primOp(g.*)) |op| if ((a.len == 2) == prims.unary(op)) {
        const p = &make(rt.Prim, 1)[0];
        sym.inlined = true;
        p.* = .{ .op = op, .sym = sym, .g = g, .f = rt.pin(g.*), .c = c };
        return .{ .prim = p };
    };
    return .{ .call = c };
}

/// Expand macros over n's AST, then build its code unless they changed nothing.
pub fn force(n: *Node) rt.E!void {
    const x = if (in_macro or rt.ptr(n.ast) == null) n.ast else try expand(n.ast);
    if (n.code == .raw or x != n.src) {
        n.code = switch (x.tag()) {
            .s => .{ .ref = .{ .sym = intern(x) } },
            .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
            .l => try form(x.asList().items()),
            else => .{ .val = x },
        };
        if (n.code == .lambda) n.code.lambda.guard = n.guard;
        n.src = rt.pin(x);
    }
    n.stamp = current();
}
