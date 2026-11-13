// Compiled code, as data: what lang/compile.zig builds from the AST, lang/eval.zig runs and vm/compiler.zig compiles further.
// Nodes, their arrays and symbols live forever (`make`), so frames and closures can keep pointing at them.
const value = @import("value.zig");
const gc = @import("gc.zig");
const Op = @import("primitives.zig").Op;
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
/// A call of a primitive with one or two operands, compiled as such while its name is global and still bound to that primitive.
/// The evaluator computes it in place when each operand is a constant, a variable or (a few levels deep) another such call, and the
/// values are numbers (or a list and an index); otherwise it makes the ordinary call c. slow: an operand cannot be computed that way.
pub const Prim = struct { op: Op, sym: *Sym, g: *V, f: V, c: []const *Node, slow: bool = false };
pub const Ref = struct { sym: *Sym, g: ?*V = null }; // g: the global slot, once found
pub const Def = struct { sym: ?*Sym, g: ?*V = null, val: *Node, define: bool }; // define or set!
/// The code of a lambda, shared by the closures made from it.
pub const Proto = struct {
    params: []const Key,
    body: *Node,
    cap: usize = 0, // room for the scope of a call, grown by defines
    rest: bool = false, // the last parameter takes the extra arguments as a list
    guard: ?*Guard = null,
    code: ?*Bytecode = null, // the tier-2 form of the body (vm/)
    tried: bool = false, // tier 2 compiled the body or rejected it (a rejected body is not tried again)
    inlined: bool = false, // other functions' bytecode contains this body: replacing the function bumps epoch
};
/// What a node does. raw: not compiled yet.
pub const Code = union(enum) {
    raw,
    val: V, // a constant
    ref: Ref, // a variable
    @"if": []const *Node, // condition, then, else
    begin: []const *Node,
    def: *Def,
    lambda: *Proto,
    prim: *Prim,
    @"&&": []const *Node,
    @"||": []const *Node,
    call: []const *Node, // the function, then the arguments
};
/// The lambda that is the last operand of a call of each or map (while that name is still global and the native): the native only
/// calls it, so creating it does not capture its scope (scope.lambda).
pub const Guard = struct { sym: *Sym, g: *V, f: V };
/// One expression. Its code is built from the (macro-expanded) AST when it is first evaluated.
pub const Node = struct {
    ast: V,
    stamp: u32 = 0, // compile.current() when code was built; 0: never
    code: Code = .raw,
    guard: ?*Guard = null, // set on the lambda operand of each/map
};

// The natives that compiled code treats specially, while their names still mean them (lib/natives.zig sets these).
/// The natives each and map themselves (not a function that merely is a step native): the loop lambda exemption and the bytecode loops are for them.
pub var each_v: V = .nil;
pub var map_v: V = .nil;
pub var range_v: V = .nil; // the native range: a loop over a call of it counts instead of building the list

/// How many items (range v) has.
pub fn rangeLen(v: V) usize {
    return @intFromFloat(@max(0, value.num(v)));
}
