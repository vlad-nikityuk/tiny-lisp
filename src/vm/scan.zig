// Before the compiler: which names of a function get fixed slots. A function body has local names: its parameters and every
// name a `define` adds anywhere in the body (in a branch, an operand, a call's argument...), but not inside a nested lambda, which
// is a function of its own. A name is local to the whole body, like an assigned name in a Python function; the slots of the
// defined names start unbound (scope.bindWith) and reading one before its define has run is an error.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const node = @import("../runtime/node.zig");
const scope = @import("../runtime/scope.zig");
const Node = node.Node;

pub const Scan = struct {
    keys: std.ArrayList(node.Key) = .empty, // the slots: parameters, then the defined names in order of first appearance

    pub fn deinit(s: *Scan) void {
        s.keys.deinit(value.gpa);
    }

    /// The slots of a function.
    pub fn function(s: *Scan, p: *node.Proto) void {
        for (p.params) |k| gc.push(node.Key, &s.keys, k);
        s.body(p.body);
    }

    fn has(s: *Scan, sym: *node.Sym) bool {
        for (s.keys.items) |k| if (k == sym.key) return true;
        return false;
    }

    /// Collect the names defined in n (not in nested lambdas). It recurses as deep as the code nests (compile.max_depth).
    fn body(s: *Scan, n: *Node) void {
        switch (n.code) {
            .val, .ref, .lambda, .empty => {},
            .@"if", .begin, .@"&&", .@"||", .call => |kids| for (kids) |k| s.body(k),
            .def => |d| {
                s.body(d.val);
                const sym = d.sym orelse return; // (define) and (set!) without a name are errors at run time
                if (!d.define) return;
                if (!s.has(sym)) gc.push(node.Key, &s.keys, sym.key);
                if (sym.inlined and !sym.local) scope.epoch +%= 1; // code compiled with the global (a primitive, each...) is out of date
                sym.local = true;
            },
        }
    }
};
