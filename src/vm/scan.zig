// Tier 2, before the compiler: which names of a function get fixed slots (its parameters and defines), and whether the
// function can be compiled at all. A name a define adds is bound from the start of the call here, while the tree evaluator
// binds it when the define runs; where the two could differ, the scan gives up and the function stays with the tree evaluator.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const node = @import("../runtime/node.zig");
const compile = @import("../lang/compile.zig");
const Node = node.Node;

const max_depth = 120; // source nesting the scan follows (it recurses)
const Held = struct { key: node.Key, level: usize };

pub const Scan = struct {
    keys: std.ArrayList(node.Key) = .empty, // the slots: parameters, then defines in the order found
    seen: std.ArrayList(node.Key) = .empty, // names read or set! so far, in scan order
    conditional_depth: usize = 0, // > 0 while scanning code that may not run (the depth of such regions)
    held: std.ArrayList(Held) = .empty, // names defined in the regions being scanned
    closed: std.ArrayList(node.Key) = .empty, // names defined in a region that is over: a later use would not be sure of the define

    pub fn deinit(s: *Scan) void {
        inline for (.{ &s.keys, &s.seen, &s.held, &s.closed }) |list| list.deinit(value.gpa);
    }

    /// The slots of a function, or error.Bail (or the error of a macro) if it cannot be compiled.
    pub fn function(s: *Scan, p: *node.Proto) !void {
        for (p.params) |k| gc.push(node.Key, &s.keys, k);
        try s.body(p.body, 0);
    }

    fn slotOf(s: *Scan, sym: *node.Sym) ?usize {
        var i = s.keys.items.len;
        while (i > 0) : (i -= 1) if (s.keys.items[i - 1] == sym.key) return i - 1;
        return null;
    }

    fn forced(n: *Node) value.E!void {
        if (n.stamp != compile.current()) try compile.force(n);
    }

    /// A use of a name (a read or a set!). After a region that defined the name it cannot be compiled; otherwise it is
    /// remembered, so that a later define of the name is rejected.
    fn use(s: *Scan, sym: *node.Sym) !void {
        if (has(s.closed.items, sym)) return error.Bail;
        if (s.slotOf(sym) == null and !has(s.seen.items, sym)) gc.push(node.Key, &s.seen, sym.key);
    }

    fn has(keys: []const node.Key, sym: *node.Sym) bool {
        for (keys) |k| if (k == sym.key) return true;
        return false;
    }

    /// The names a nested lambda reads or sets count as used where the lambda is made (it may run before a later define of
    /// the same name). Its own defines are not this function's: they get no slot here.
    fn uses(s: *Scan, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val => {},
            .ref => |r| try s.use(r.sym),
            .@"if", .begin, .@"&&", .@"||", .call => |kids| for (kids) |k| try s.uses(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try s.uses(k, depth + 1),
            .def => |d| {
                try s.uses(d.val, depth + 1);
                if (!d.define) if (d.sym) |sym| try s.use(sym);
            },
            .lambda => |lp| try s.uses(lp.body, depth + 1),
            else => return error.Bail,
        }
    }

    /// Start of a region that may not run (a branch of an if, a later operand of && or ||).
    fn enter(s: *Scan) void {
        s.conditional_depth += 1;
    }

    /// End of such a region: the names it defined can no longer be used (they are bound from the start of the call,
    /// but only defined if the region ran).
    fn leave(s: *Scan) void {
        s.conditional_depth -= 1;
        while (s.held.items.len > 0 and s.held.items[s.held.items.len - 1].level > s.conditional_depth) {
            gc.push(node.Key, &s.closed, s.held.items[s.held.items.len - 1].key);
            s.held.items.len -= 1;
        }
    }

    /// Find the defines of the body (they get slots) and reject what this tier does not do. A name a define adds is bound from the
    /// start of the call, so a define that may not run, or comes after a use of the same name (which would then mean an outer
    /// binding), is left to the tree evaluator, where the name is only bound once the define has run.
    fn body(s: *Scan, n: *Node, depth: usize) !void {
        if (depth > max_depth) return error.Bail;
        try forced(n);
        switch (n.code) {
            .val => {},
            .lambda => |lp| try s.uses(lp.body, depth + 1),
            .ref => |r| try s.use(r.sym),
            .@"if" => |k| {
                try s.body(k[0], depth + 1);
                s.enter();
                try s.body(k[1], depth + 1);
                s.leave();
                s.enter();
                try s.body(k[2], depth + 1);
                s.leave();
            },
            .@"&&", .@"||" => |k| for (k, 0..) |x, i| {
                if (i > 0) s.enter();
                try s.body(x, depth + 1);
                if (i > 0) s.leave();
            },
            .begin, .call => |kids| for (kids) |k| try s.body(k, depth + 1),
            .prim => |p| for (p.c[1..]) |k| try s.body(k, depth + 1),
            .def => |d| {
                try s.body(d.val, depth + 1);
                const sym = d.sym orelse return error.Bail;
                if (!d.define) return s.use(sym);
                if (has(s.closed.items, sym) or has(s.seen.items, sym)) return error.Bail;
                if (s.slotOf(sym) == null) gc.push(node.Key, &s.keys, sym.key);
                if (s.conditional_depth > 0) gc.push(Held, &s.held, .{ .key = sym.key, .level = s.conditional_depth });
                sym.local = true;
            },
            else => return error.Bail,
        }
    }
};
