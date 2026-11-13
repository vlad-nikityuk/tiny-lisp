// Scopes: the variables of each call, the global table, and the recycling of scopes whose call is over.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const V = rt.V;
const E = rt.E;
const Key = rt.Key;
const Sym = rt.Sym;
const Proto = rt.Proto;
const Lam = rt.Lam;

/// A scope: the variables of one call. The root scope has none: its names are in the global table.
pub const Env = struct {
    p: ?*Env, // the enclosing scope
    vars: []Var, // stored inline, right after the Env, until they outgrow cap
    cap: usize,
    proto: ?*Proto = null, // the function whose call this is
    recyclable: bool = false, // `release` may hand it to a free list: it has a pooled size, no closure holds it or an inner scope, and it is not on a list yet
    captured: bool = false, // a closure holds it or an inner scope: a loop or a self tail call must not use it again
};
pub const Var = struct { k: Key, v: V };

// The root scope keeps its names in the global table: open addressing, FNV-1a.
pub var gk: [1 << 13]?[*:0]const u8 = @splat(null);
pub var gv: [1 << 13]V = @splat(.nil);
/// The root slots of the macro/* functions.
pub var macros: std.ArrayList(*V) = .empty;
pub var root: *Env = undefined;

/// Create the root scope: it lives forever.
pub fn init() *Env {
    root = @ptrCast(@alignCast(gc.perm(@sizeOf(Env))));
    root.* = .{ .p = null, .vars = &.{}, .cap = 0 };
    return root;
}

// Two counters say when compiled code is out of date.
/// Bumped when a macro/* is defined, or when a value that tier-2 code was compiled with (a native, an inlined function) is
/// replaced: all code compiles again (lang.current).
pub var epoch: u32 = 0;
/// Bumped when a name is added to a scope whose layout tier-2 code relies on (by load, say): remembered lookups are void.
pub var shape: u32 = 1;

// lookup and assignment
// ----------------------------------------------------------------
/// The variable k of e itself (enclosing scopes are not searched).
pub fn slotOf(e: *Env, k: Key) ?*V {
    return slot(e, k, false);
}

fn slot(e: *Env, k: Key, create: bool) ?*V {
    if (e.p == null) {
        var i: usize = std.hash.Fnv1a_32.hash(std.mem.span(k)) & (gk.len - 1);
        while (gk[i]) |key| : (i = (i + 1) & (gk.len - 1)) if (rt.streq(key, k)) return &gv[i];
        if (create) gk[i] = k;
        return if (create) &gv[i] else null;
    }
    var i = e.vars.len; // the latest binding of a name wins
    while (i > 0) : (i -= 1) if (e.vars[i - 1].k == k) return &e.vars[i - 1].v;
    if (!create) return null;
    if (e.vars.len == e.cap) {
        const more = rt.gpa.alloc(Var, e.cap * 2) catch gc.oom();
        @memcpy(more[0..e.cap], e.vars);
        if (e.vars.ptr != gc.after(Var, e)) rt.gpa.free(e.vars);
        e.vars.ptr, e.cap = .{ more.ptr, more.len };
        if (e.proto) |p| p.cap = e.cap; // the next call of this function gets a scope that is big enough
    }
    if (e.proto != null and e.proto.?.code != null) shape +%= 1;
    e.vars.len += 1;
    e.vars[e.vars.len - 1] = .{ .k = k, .v = .nil };
    return &e.vars[e.vars.len - 1].v;
}

/// The innermost binding of the name: scope keys are interned, so they are compared by address. A name that no scope binds
/// is global without searching. g caches the global slot.
pub fn find(env: *Env, sym: *Sym, g: *?*V) ?*V {
    var e = env;
    while (sym.local and e.p != null) : (e = e.p.?) {
        var i = e.vars.len;
        while (i > 0) : (i -= 1) if (e.vars[i - 1].k == sym.key) return &e.vars[i - 1].v;
    }
    if (g.* == null) g.* = slot(root, sym.key, false);
    return g.*;
}

/// The global slot of a name that no scope binds: only then does the name always mean the global.
pub fn globalOf(sym: *Sym) ?*V {
    return if (sym.local) null else slot(root, sym.key, false);
}

pub fn fetch(env: *Env, r: *rt.Ref) V {
    return if (find(env, r.sym, &r.g)) |p| p.* else .nil;
}

/// define or set!.
pub fn assign(d: *rt.Def, e: *Env, v: V) E!void {
    const sym = d.sym orelse return rt.fail(rt.str("TinyLisp: {s} needs a name", .{if (d.define) "define" else "set!"}));
    if (d.define) {
        if (sym.inlined and !sym.local and e.p != null) epoch +%= 1;
        sym.local = sym.local or e.p != null;
        set(e, sym.key, v);
    } else if (find(e, sym, &d.g)) |p| replace(p, v);
}

/// set! of the variable at p. If its old value is compiled into tier-2 code, that code is out of date.
pub inline fn replace(p: *V, v: V) void {
    if (compiledInto(p.*)) epoch +%= 1;
    p.* = v;
}

/// Root keys are copied to permanent memory; scope keys are interned already.
pub fn set(e: *Env, key: Key, v: V) void {
    const s = slot(e, key, false) orelse blk: {
        const s = slot(e, if (e.p != null) key else rt.mkstr(std.mem.span(key), true), true).?;
        if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) gc.push(*V, &macros, s);
        break :blk s;
    };
    if (e.p == null and compiledInto(s.*)) epoch +%= 1; // a native (maybe a primitive that tier-2 code inlines) or an inlined function is replaced
    s.* = v;
    if (e.p == null and std.mem.startsWith(u8, std.mem.span(key), "macro/")) epoch +%= 1;
}

/// Replacing this value must compile the tier-2 code again: it is a native, or a function that other functions' code contains.
pub fn compiledInto(v: V) bool {
    return v.is(.f) or (v.is(.lam) and v.asLam().proto.inlined);
}

// closures and recycling
// ----------------------------------------------------------------
/// A closure of p over e. It holds the scope and, through it, the enclosing ones: none can be recycled when its call ends.
/// Except the body of a loop (the lambda given to the native each or map, see rt.Guard): it is dead once the loop is over.
pub fn lambda(p: *Proto, e: *Env) V {
    const loop_body = if (p.guard) |d| !d.sym.local and d.g.* == d.f else false;
    var s: ?*Env = if (loop_body) null else e;
    while (s) |x| : (s = x.p) {
        x.recyclable = false;
        x.captured = true;
    }
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

pub fn bind(f: *Lam, a: []const V) *Env {
    return bindWith(f, a, f.proto.code);
}

/// The scope of a call of f; for tier-2 code (`code`), the defines of the body have their slots from the start.
pub fn bindWith(f: *Lam, a: []const V, code: ?*rt.Bytecode) *Env {
    const ps = f.proto.params;
    const n = if (code) |c| c.keys.len else ps.len;
    const cap = capFor(@max(f.proto.cap, n));
    const pool = poolOf(cap);
    const e = if (pool != null and env_pools[pool.?] != null) blk: {
        const e = env_pools[pool.?].?;
        env_pools[pool.?] = e.p;
        break :blk e;
    } else gc.new(Env, cap * @sizeOf(Var), .env, undefined);
    e.* = .{ .p = f.env, .vars = gc.after(Var, e)[0..n], .cap = cap, .proto = f.proto, .recyclable = pool != null };
    const fixed = ps.len - @intFromBool(f.proto.rest); // a last parameter after & takes the extra arguments as a list
    for (ps[0..fixed], e.vars[0..fixed], 0..) |k, *x, i| x.* = .{ .k = k, .v = rt.arg(a, i) };
    if (f.proto.rest) e.vars[fixed] = .{ .k = ps[fixed], .v = rt.list(if (a.len > fixed) a[fixed..] else &.{}, a.len -| fixed) };
    if (code) |c| for (c.keys[ps.len..], e.vars[ps.len..]) |k, *x| {
        x.* = .{ .k = k, .v = .nil };
    };
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
