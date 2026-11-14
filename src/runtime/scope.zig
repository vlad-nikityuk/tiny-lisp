// Scopes: the variables of each call, the global table, and the recycling of scopes whose call is over.
const std = @import("std");
const value = @import("value.zig");
const gc = @import("gc.zig");
const node = @import("node.zig");
const bytecode = @import("../vm/bytecode.zig");
const V = value.V;
const E = value.E;
const Key = node.Key;
const Sym = node.Sym;
const Proto = node.Proto;
const Lam = value.Lam;

/// A scope: the variables of one call. The root scope has none: its names are in the global table.
pub const Env = struct {
    p: ?*Env, // the enclosing scope
    vars: []Var, // stored inline, right after the Env: the slots of the function's bytecode (parameters, then defined names)
    cap: usize, // room for vars (a pooled size)
    proto: ?*Proto = null, // the function whose call this is
    recyclable: bool = false, // `release` may hand it to a free list: it has a pooled size, no closure holds it or an inner scope, and it is not on a list yet
    captured: bool = false, // a closure holds it or an inner scope: a loop or a self tail call must not use it again
};
pub const Var = struct { k: Key, v: V };

// The root scope keeps its names in the global table: open addressing, FNV-1a.
pub var gk: [1 << 13]?[*:0]const u8 = @splat(null);
pub var gv: [1 << 13]V = @splat(.nil);
/// The macros: name -> function, filled by defmacro (lang/expand.zig). The collector marks the functions.
pub var macros: std.StringHashMapUnmanaged(V) = .empty;
pub var root: *Env = undefined;

/// Create the root scope: it lives forever.
pub fn init() *Env {
    root = @ptrCast(@alignCast(gc.perm(@sizeOf(Env))));
    root.* = .{ .p = null, .vars = &.{}, .cap = 0 };
    return root;
}

/// Bumped when a value that compiled code was compiled with (a native, an inlined function) is replaced: all code compiles
/// again (`ready` in vm/compiler.zig).
pub var epoch: u32 = 0;

// lookup and assignment
// ----------------------------------------------------------------
/// The global slot of k, created if `create`. (A function's scope has a fixed layout: its names are the slots the compiler gave it.)
fn global(k: Key, create: bool) ?*V {
    var i: usize = std.hash.Fnv1a_32.hash(std.mem.span(k)) & (gk.len - 1);
    while (gk[i]) |key| : (i = (i + 1) & (gk.len - 1)) if (value.streq(key, k)) return &gv[i];
    if (create) gk[i] = k;
    return if (create) &gv[i] else null;
}

/// The slot of the global k, if there is one.
pub fn slotOf(k: Key) ?*V {
    return global(k, false);
}

/// The innermost binding of the name: scope keys are interned, so they are compared by address. A name that no scope binds
/// is global without searching. g caches the global slot.
pub fn find(env: *Env, sym: *Sym, g: *?*V) ?*V {
    var e = env;
    while (sym.local and e.p != null) : (e = e.p.?) {
        var i = e.vars.len;
        while (i > 0) : (i -= 1) if (e.vars[i - 1].k == sym.key) return &e.vars[i - 1].v;
    }
    if (g.* == null) g.* = global(sym.key, false);
    return g.*;
}

/// The global slot of a name that no scope binds: only then does the name always mean the global.
pub fn globalOf(sym: *Sym) ?*V {
    return if (sym.local) null else global(sym.key, false);
}

pub fn usedBeforeDefined(name: Key) E {
    return value.fail(value.str("TinyLisp: {s} is used before it is defined", .{name}));
}

/// set! of a name that no scope and no global binds.
pub fn notDefined(name: Key) E {
    return value.fail(value.str("TinyLisp: set!: {s} is not defined", .{name}));
}

/// A define the compiler has no slot for: a global define (top-level code). A define or set! without a name is an error.
pub fn assign(d: *node.Def, v: V) E!void {
    const sym = d.sym orelse return value.fail(value.str("TinyLisp: {s} needs a name", .{if (d.define) "define" else "set!"}));
    set(root, sym.key, v);
}

/// set! of the variable at p. If its old value is compiled into compiled code, that code is out of date.
pub inline fn replace(p: *V, v: V) void {
    if (compiledInto(p.*)) epoch +%= 1;
    p.* = v;
}

/// Define the global key in the root scope e, copying the key to permanent memory.
pub fn set(e: *Env, key: Key, v: V) void {
    std.debug.assert(e.p == null);
    const s = global(key, false) orelse global(value.mkstr(std.mem.span(key), true), true).?;
    if (compiledInto(s.*)) epoch +%= 1; // a native (maybe a primitive that compiled code inlines) or an inlined function is replaced
    s.* = v;
}

/// Replacing this value must compile the compiled code again: it is a native, or a function that other functions' code contains.
fn compiledInto(v: V) bool {
    return v.is(.f) or (v.is(.lam) and v.asLam().proto.inlined);
}

// closures and recycling
// ----------------------------------------------------------------
/// A continuation or closure captured these scopes: keep them and do not recycle them for loops or self tail calls.
pub fn hold(e: ?*Env) void {
    var s = e;
    while (s) |x| : (s = x.p) {
        x.recyclable = false;
        x.captured = true;
    }
}

/// A closure of p over e. It holds the scope and, through it, the enclosing ones: none can be recycled when its call ends.
/// Except the body of a loop (the lambda given to the native each or map, see node.Guard): it is dead once the loop is over.
pub fn lambda(p: *Proto, e: *Env) V {
    const loop_body = if (p.guard) |d| !d.sym.local and d.g.* == d.f else false;
    if (!loop_body) hold(e);
    return V.lamOf(gc.new(Lam, 0, .lam, .{ .proto = p, .env = e }));
}

// Most scopes die when their call ends: a call's scope is recycled then, unless a closure captured it. Recycled scopes wait on
// free lists by capacity (linked through `p`); the collector forgets the lists, so whatever they hold is simply collected.
const pool_caps = [_]usize{ 4, 8, 16 };
pub var env_pools: [pool_caps.len]?*Env = @splat(null);

fn poolOf(cap: usize) ?usize {
    return switch (cap) {
        4 => 0,
        8 => 1,
        16 => 2,
        else => null,
    };
}

/// The capacity a scope for n variables gets: one of the pooled sizes if it fits.
fn capFor(n: usize) usize {
    for (pool_caps) |c| if (n <= c) return c;
    return n;
}

/// The scope of a call of f, whose body is compiled (compiler.ready).
pub fn bind(f: *Lam, a: []const V) *Env {
    return bindWith(f, a, f.proto.code.?);
}

/// The scope of a call of f running `code`: the defines of the body have their slots from the start.
pub fn bindWith(f: *Lam, a: []const V, code: *bytecode.Bytecode) *Env {
    const ps = f.proto.params;
    const n = code.keys.len;
    const cap = capFor(n);
    const pool = poolOf(cap);
    const e = if (pool != null and env_pools[pool.?] != null) blk: {
        const e = env_pools[pool.?].?;
        env_pools[pool.?] = e.p;
        break :blk e;
    } else gc.new(Env, cap * @sizeOf(Var), .env, undefined);
    e.* = .{ .p = f.env, .vars = gc.after(Var, e)[0..n], .cap = cap, .proto = f.proto, .recyclable = pool != null };
    const fixed = ps.len - @intFromBool(f.proto.rest); // a last parameter after & takes the extra arguments as a list
    for (ps[0..fixed], e.vars[0..fixed], 0..) |k, *x, i| x.* = .{ .k = k, .v = value.arg(a, i) };
    if (f.proto.rest) e.vars[fixed] = .{ .k = ps[fixed], .v = value.list(if (a.len > fixed) a[fixed..] else &.{}, a.len -| fixed) };
    for (code.keys[ps.len..], e.vars[ps.len..]) |k, *x| x.* = .{ .k = k, .v = V.unbound }; // a define has not run yet
    return e;
}

/// The call that ran in e is over (nothing but a closure could still use it).
pub fn release(e: *Env) void {
    if (!e.recyclable or e.p == null or e.vars.ptr != gc.after(Var, e)) return;
    const pool = poolOf(e.cap) orelse return;
    e.recyclable = false; // never twice
    e.p = env_pools[pool];
    env_pools[pool] = e;
}
