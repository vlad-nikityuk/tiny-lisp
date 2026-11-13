// The machine's state: pending work lives in heap frames (ks) and values on one stack (vs), so nothing grows the native
// stack. lang/eval.zig is the loop that runs it; vm/exec.zig runs bytecode on the same two stacks. Also here: the protocol
// of natives that call back into Lisp, which run as frames, and the two natives built on it, try and the trampoline.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const scope = @import("scope.zig");
const V = rt.V;
const E = rt.E;
const Fn = rt.Fn;
const Env = scope.Env;
const Node = rt.Node;
const Def = rt.Def;
const Bytecode = rt.Bytecode;
const gpa = rt.gpa;
const arg = rt.arg;
const list = rt.list;
const nf = rt.nf;

pub const Kind = enum { @"if", @"&&", @"||", begin, def, call, native, vm, loop };
/// Pending work: what to do with the next value. One flat struct for every kind (a frame is pushed per call, so it stays small
/// and is written in one go); each kind uses the fields it needs.
pub const Frame = struct {
    kind: Kind,
    i: usize, // begin, &&, ||, call: the item being evaluated; native: its own state; vm, loop: the instruction to resume at
    base: usize, // call, native: where the function and its arguments start on vs; vm, loop: the top of vs to return to
    c: []const *Node, // if, begin, &&, ||, call: the items
    d: *Def = undefined, // def
    e: *Env, // the scope to go back to
    code: *Bytecode = undefined, // vm, loop: the bytecode to resume
    iter_env: ?*Env = null, // loop: the scope of the iteration that is running, which the next one reuses if nothing captured it
};
/// A running evaluator loop: its scope is a root for the collector. ks[base..] are its frames.
pub const Machine = struct { e: *Env, base: usize };
pub var machines: std.ArrayList(*Machine) = .empty;
/// What the machine does next. eval: evaluate a node; ret: hand a value to the innermost frame; vm: run bytecode from pc;
/// apply: call the function at vs[apply] with the arguments after it; args: collect a call's items from c[i] on, they start at vs[b].
pub const Go = union(enum) { eval: *Node, ret: V, vm: struct { code: *Bytecode, pc: usize }, apply: usize, args: struct { c: []const *Node, i: usize, b: usize } };

pub var ks: std.ArrayList(Frame) = .empty; // the frames
pub var vs: std.ArrayList(V) = .empty; // the values: functions and arguments being collected, native frames' state, the bytecode's stack

pub fn frame(kind: Kind, c: []const *Node, e: *Env) *Frame {
    gc.push(Frame, &ks, .{ .kind = kind, .i = 0, .base = vs.items.len, .c = c, .e = e });
    return &ks.items[ks.items.len - 1];
}

/// Push the value of c[i], an item of a call: the function first, which must exist.
pub inline fn operand(c: []const *Node, i: usize, v: V) E!void {
    if (i == 0 and v == V.nil) return rt.undefinedFunction(c[0].ast);
    gc.push(V, &vs, v);
}

// natives that call back into Lisp
// ----------------------------------------------------------------
// They run as frames: a native frame's arguments sit on vs right after the native itself (vs[k.base]),
// its state goes after them.

/// Push the frame of the native at vs[b] (its arguments follow it) and run its first step.
pub fn start(b: usize, e: *Env) E!Go {
    const k = frame(.native, &.{}, e);
    k.base = b;
    return step(k, null);
}

/// Resume a native frame with the value of its callback (null: first step).
pub fn step(k: *Frame, v: ?V) E!Go {
    const n = vs.items[k.base].asFn();
    return n.f.step(n, k, v);
}

/// The frame's arguments, padded with nil or cut to exactly n (so state can follow them).
pub fn frameArgs(k: *Frame, n: usize) []V {
    const end = k.base + 1 + n;
    while (vs.items.len < end) gc.push(V, &vs, .nil);
    vs.items.len = end;
    return vs.items[k.base + 1 ..];
}

/// Pop the frame and hand v to the next one.
pub fn finish(k: *Frame, v: V) Go {
    vs.items.len = k.base;
    ks.items.len -= 1;
    return .{ .ret = v };
}

/// Call f with xs (which must not live on vs); its value comes back to this frame.
pub fn callback(f: V, xs: []const V) Go {
    const b = vs.items.len;
    gc.push(V, &vs, f);
    vs.appendSlice(gpa, xs) catch gc.oom();
    return .{ .apply = b };
}

/// Replace the frame by a call of f with pre, then (if keep) the frame's arguments: f runs in tail position.
pub fn tail(k: *Frame, f: V, pre: []const V, keep: bool) Go {
    const b = k.base;
    if (!keep) vs.items.len = b + 1;
    vs.items[b] = f;
    vs.insertSlice(gpa, b + 1, pre) catch gc.oom();
    ks.items.len -= 1;
    return .{ .apply = b };
}

/// (try thunk handler) calls thunk; after an error, `recover` resumes the frame with k.i = 1 and the error value.
fn tryRun(_: *Fn, k: *Frame, v: ?V) E!Go {
    const a = frameArgs(k, 2);
    const r = v orelse return callback(a[0], &.{});
    return if (k.i == 1) tail(k, a[1], &.{r}, false) else finish(k, r);
}

/// After an error: drop the frames above the innermost try frame at or above base and resume it, if there is one.
pub fn recover(base: usize) ?Go {
    var j = ks.items.len;
    while (j > base) {
        j -= 1;
        const k = &ks.items[j];
        if (k.kind != .native or vs.items[k.base].asFn().f.step != &tryRun) continue;
        ks.items.len = j + 1;
        vs.items.len = k.base + 3; // try, thunk, handler
        k.i = 1;
        return .{ .ret = rt.errv };
    }
    return null;
}

// trampoline: nested calls while active return thunks, the outermost runs them in a loop
fn thunk(s: *Fn, k: *Frame, _: ?V) E!Go {
    return tail(k, s.d0, s.d1.asList().items(), false);
}

/// (trampoline f) is the function that runs f that way.
fn trampoline(_: *Fn, a: []const V) E!V {
    return V.fnOf(nf(.{ .step = trampRun }, arg(a, 0), .nil));
}

/// s.i - 1 is the index of the outermost run's frame. It is checked, not trusted: a frame dropped by an error
/// never finishes and so never clears it.
fn trampRun(s: *Fn, k: *Frame, v: ?V) E!Go {
    const frames = ks.items;
    const r = v orelse {
        const j = s.i -% 1;
        if (j < frames.len - 1 and frames[j].kind == .native and vs.items[frames[j].base].asFn() == s) {
            const a = vs.items[k.base + 1 ..];
            return finish(k, V.fnOf(nf(.{ .step = thunk }, s.d0, list(a, a.len))));
        }
        s.i = frames.len;
        vs.insertSlice(gpa, k.base + 1, &.{s.d0}) catch gc.oom(); // call s.d0 with the frame's arguments
        return .{ .apply = k.base + 1 };
    };
    if (r.is(.f) or r.is(.lam)) return callback(r, &.{});
    s.i = 0;
    return finish(k, r);
}

/// Define try and trampoline in the root scope.
pub fn install(e: *Env) void {
    scope.set(e, "try", V.fnOf(nf(.{ .step = tryRun }, .nil, .nil)));
    scope.set(e, "trampoline", V.fnOf(nf(.{ .plain = trampoline }, .nil, .nil)));
}
