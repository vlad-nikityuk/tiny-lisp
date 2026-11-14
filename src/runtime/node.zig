// The typed AST, as data: what lang/compile.zig builds from the (expanded) AST and vm/compiler.zig turns into bytecode.
// Nodes, their arrays and symbols live forever (`make`), so closures (`Proto`) can keep pointing at them.
const value = @import("value.zig");
const gc = @import("gc.zig");
const Bytecode = @import("../vm/bytecode.zig").Bytecode;
const V = value.V;

/// n permanent Ts (compiled code lives forever).
pub fn make(comptime T: type, n: usize) []T {
    return @as([*]T, @ptrCast(@alignCast(gc.perm(n * @sizeOf(T)))))[0..n];
}

pub const Key = [*:0]const u8; // a symbol, interned: equal names are the same pointer
pub const Sym = struct {
    key: Key,
    local: bool = false, // some scope binds this name (a parameter, or a define inside a function); otherwise it can only be global
    inlined: bool = false, // compiled code relies on the global value of this name (a primitive, each, map, range): binding it locally bumps epoch
};
pub const Ref = struct { sym: *Sym, g: ?*V = null }; // g: the global slot, once found
pub const Def = struct { sym: ?*Sym, g: ?*V = null, val: *Node, define: bool }; // define or set!
/// The code of a lambda, shared by the closures made from it.
pub const Proto = struct {
    params: []const Key,
    body: *Node,
    cap: usize = 0, // room for the scope of a call, grown by defines
    rest: bool = false, // the last parameter takes the extra arguments as a list
    guard: ?*Guard = null, // set by the bytecode compiler on the lambda operand of each/map
    code: ?*Bytecode = null, // the bytecode of the body, compiled on the first call (vm/compiler.zig `ready`)
    inlined: bool = false, // other functions' bytecode contains this body: replacing the function bumps epoch
};
/// What a node does.
pub const Code = union(enum) {
    val: V, // a constant
    ref: Ref, // a variable
    @"if": []const *Node, // condition, then, else
    begin: []const *Node,
    def: *Def,
    lambda: *Proto,
    @"&&": []const *Node,
    @"||": []const *Node,
    call: []const *Node, // the function, then the arguments
    empty, // `()`: evaluating it is an error, raised when (and only if) it runs
};
/// The lambda that is the last operand of a call of each or map (while that name is still global and the native): the native only
/// calls it, so creating it does not capture its scope (scope.lambda).
pub const Guard = struct { sym: *Sym, g: *V, f: V };
/// One expression, built from the (macro-expanded) AST. ast: the form it was built from.
pub const Node = struct { ast: V, code: Code };

// The natives that compiled code treats specially, while their names still mean them (lib/natives.zig sets these).
/// The natives each and map themselves (not a function that merely is a step native): the loop lambda exemption and the bytecode loops are for them.
pub var each_v: V = .nil;
pub var map_v: V = .nil;
pub var range_v: V = .nil; // the native range: a loop over a call of it counts instead of building the list

/// How many items (range v) has.
pub fn rangeLen(v: V) usize {
    return @intFromFloat(@max(0, value.num(v)));
}
