// The bytecode format: a function body (or a top-level form) as a stack bytecode over fixed scope slots. compiler.zig produces it, exec.zig runs it.
const value = @import("../runtime/value.zig");
const node = @import("../runtime/node.zig");
const primitives = @import("../runtime/primitives.zig");
const V = value.V;

// zig fmt: off
/// The instructions. a, b: the operands in the instruction (Ins); "push", "pop" and "top" are about the stack of values.
pub const Opcode = enum(u8) {
    // values
    konst,      // push consts[a]
    local,      // push slot a of the scope
    local_checked, // the same for a name defined in this function where its define may not have run: unbound is an error (refs[b]: the name)
    outer,      // push the variable refs[a], which is in an enclosing scope or global (b: where it was found, see outerSlot in exec.zig)
    global,     // push the global refs[a] (a free name of an inlined function)
    lambda,     // push a closure of protos[a] over the scope
    // assignments (define and set! have a value, so it stays on the stack)
    setlocal,   // slot a = top
    setouter,   // set! defs[a], a name outside this function's slots (b as in outer): an error if no scope and no global has it
    setglobal,  // set! the global defs[a] (an error if there is none)
    assign,     // define or set! defs[a] the general way (scope.assign): a global define of top-level code, or a form without a name, which is an error
    storelocal, // slot a = pop (an argument of an inlined function)
    pop,
    empty,      // the form `()`: an error
    // control
    jmp,        // go to instruction b
    jmpf,       // pop; go to b if it was false
    andj, orj,  // && and ||: if top decides the result (false for &&, true for ||) go to b, else pop
    call,       // call the function that is under its a arguments; the value replaces them (consts[b]: its source, for an error)
    tailcall,   // the same in tail position: the call replaces this function's
    ret,        // return top
    // primitives, compiled while their names were bound to the natives. prims[a] is the call, made the ordinary way (slow in exec.zig)
    // when the operands are not plain numbers (or a list and an index).
    not,        // top = (not top)
    prim1,      // top = (prims[a].op top): abs floor sqrt exp log cos
    add, sub, mul, div, mod, lt, gt, le, ge, eq, at, // pop y; top = (op top y)
    // The same, fused with the operands: the first is l (the local in slot b >> 16) or s (top of the stack), the second is
    // l (a local) or k (a constant), by its index in b's low 16 bits. The l forms push the value, the s forms replace top.
    add_lk, add_ll, sub_lk, sub_ll, mul_lk, mul_ll, lt_lk, lt_ll, gt_lk, gt_ll, le_lk, le_ll, ge_lk, ge_ll, eq_lk, eq_ll, at_lk, at_ll,
    add_sk, add_sl, sub_sk, sub_sl, mul_sk, mul_sl, lt_sk, lt_sl, gt_sk, gt_sl, le_sk, le_sl, ge_sk, ge_sl, eq_sk, eq_sl, at_sk, at_sl,
    vset,       // (vset! list index value) on the three top values; consts[a]: the native, which does all but an in-range store
    vset_ll,    // the same with the list in slot b >> 16 and the index in slot b & 0xffff: top stays, as the value
    // loops: (each list (lambda (x) ...)) and (map ...); protos[a] is the lambda, bodies[a] its bytecode.
    // b != 0: the list is (range n) and only n is on the stack, the loop counts.
    each, map,         // the list is on top: push the rest of the loop's state
    eachnext, mapnext, // run the body with the next item (it comes back here with `ret`), or end with the loop's value
};
// zig fmt: on

/// The instructions for a two-operand primitive, and those of them that have fused forms.
pub const binary = [_]Opcode{ .add, .sub, .mul, .div, .mod, .lt, .gt, .le, .ge, .eq, .at };
pub const fusable = [_]Opcode{ .add, .sub, .mul, .lt, .gt, .le, .ge, .eq, .at };

/// The primitive that a two-operand instruction, plain or fused, computes.
pub fn primOf(comptime op: Opcode) primitives.Op {
    return switch (op) {
        .add, .add_lk, .add_ll, .add_sk, .add_sl => .@"+",
        .sub, .sub_lk, .sub_ll, .sub_sk, .sub_sl => .@"-",
        .mul, .mul_lk, .mul_ll, .mul_sk, .mul_sl => .@"*",
        .div => .@"/",
        .mod => .mod,
        .lt, .lt_lk, .lt_ll, .lt_sk, .lt_sl => .@"<",
        .gt, .gt_lk, .gt_ll, .gt_sk, .gt_sl => .@">",
        .le, .le_lk, .le_ll, .le_sk, .le_sl => .@"<=",
        .ge, .ge_lk, .ge_ll, .ge_sk, .ge_sl => .@">=",
        .eq, .eq_lk, .eq_ll, .eq_sk, .eq_sl => .@"eq?",
        .at, .at_lk, .at_ll, .at_sk, .at_sl => .at,
        else => unreachable,
    };
}

/// The fused form of op for the operands "lk", "ll", "sk" or "sl": add_lk for add.
pub fn fused(comptime op: Opcode, comptime operands: []const u8) Opcode {
    return @field(Opcode, @tagName(op) ++ "_" ++ operands);
}

/// Is the second operand of a fused instruction a constant (else a local)?
pub fn secondIsConst(comptime op: Opcode) bool {
    const name = @tagName(op);
    return name[name.len - 1] == 'k';
}

/// A call of a primitive that became an instruction (the ordinary call it falls back to is made through the name, `slow` in exec.zig).
pub const PrimCall = struct { op: primitives.Op, sym: *node.Sym, head: V };

/// One instruction. a, b: its operands (see Opcode). An outer lookup also notes where it found the name in b.
pub const Ins = struct { op: Opcode, a: u16 = 0, b: u32 = 0 };
/// The compiled body of a function, or of a top-level form (a function without parameters, run in the root scope).
/// Instructions refer to the tables by index.
pub const Bytecode = struct {
    ins: []Ins,
    consts: []const V,
    refs: []const *node.Ref, // names read outside this function's slots
    prims: []const PrimCall, // primitive calls, for the ordinary call when the operands are not plain numbers
    defs: []const *node.Def, // define/set! of names outside this function's slots
    protos: []const *node.Proto, // lambdas
    bodies: []const ?*Bytecode, // by the same index as protos: the compiled body of a loop lambda
    keys: []const node.Key, // the names of the scope's slots: parameters, then defines, then the slots of inlined functions
    stamp: u32, // scope.epoch when it was compiled: out of date after a rebound primitive or inlined function
    room: usize, // the most values it can have on the stack
};
