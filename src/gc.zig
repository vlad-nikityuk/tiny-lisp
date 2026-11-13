// Mark-sweep memory manager.
//
// Every managed object is malloc'd with a header and linked into one list. Nothing is counted and nothing is swept per
// call: the evaluator and VM collect at rooted transitions and backedges, publishing the VM stack length first.
// Every live managed value must be reachable from roots, even if also held in a Zig local. Marking uses a
// worklist, never recursion; sweeping frees what stayed unmarked. Cycles (a closure stored in the scope it captures) are
// collected like anything else. Permanent objects (parser symbols and literals, the root scope) are never collected.
const std = @import("std");
const rt = @import("runtime.zig");
const lang = @import("lang.zig");
const V = rt.V;

pub const Kind = enum(u3) { perm, str, list, func, lam, env };
/// Header in front of every object, one word: the next object's address (16-aligned, so its low bits are free) with the
/// mark in bit 0 and the kind in bits 1-3.
const H = extern struct { link: usize };

var all: ?*H = null;
var gray: std.ArrayList(*H) = .empty; // marked, children not yet visited
var allocated: usize = 0; // bytes since the last collection
var limit: usize = 2 << 20; // collect when allocated passes this; follows the live size

inline fn nextOf(h: *H) ?*H {
    return @ptrFromInt(h.link & ~@as(usize, 15));
}

inline fn setNext(h: *H, n: ?*H) void {
    h.link = h.link & 15 | @intFromPtr(n);
}

inline fn kindOf(h: *H) Kind {
    return @fromBackingInt(@intCast(h.link >> 1 & 7));
}

inline fn isMarked(h: *H) bool {
    return h.link & 1 != 0;
}

pub fn oom() noreturn {
    std.debug.print("TinyLisp: out of memory\n", .{});
    std.process.exit(1);
}

pub inline fn push(comptime T: type, list: *std.ArrayList(T), x: T) void {
    if (list.items.len < list.capacity) {
        list.items.len += 1;
        list.items[list.items.len - 1] = x;
    } else grow(T, list, x);
}

noinline fn grow(comptime T: type, list: *std.ArrayList(T), x: T) void {
    list.append(std.heap.c_allocator, x) catch oom();
}

fn header(p: *anyopaque) *H {
    return @ptrFromInt(@intFromPtr(p) - @sizeOf(H));
}

fn body(h: *H) *anyopaque {
    return @ptrFromInt(@intFromPtr(h) + @sizeOf(H));
}

/// The items stored right after a struct (lists and scopes keep their arrays inline).
pub fn after(comptime Item: type, p: anytype) [*]Item {
    const T = @typeInfo(@TypeOf(p)).pointer.child;
    return @ptrCast(@alignCast(@as([*]T, @ptrCast(p)) + 1));
}

fn calloc(n: usize) *H {
    return @ptrCast(@alignCast(std.c.calloc(1, @sizeOf(H) + n) orelse oom()));
}

fn malloc(n: usize) *H {
    return @ptrCast(@alignCast(std.c.malloc(@sizeOf(H) + n) orelse oom()));
}

/// Not zeroed: the caller sets every byte it uses.
pub fn alloc(n: usize, kind: Kind) *anyopaque {
    const h = malloc(n);
    h.link = @intFromPtr(all) | @as(usize, @backingInt(kind)) << 1;
    all = h;
    allocated += n + @sizeOf(H);
    return body(h);
}

/// `extra` bytes follow the T.
pub fn new(comptime T: type, extra: usize, kind: Kind, init: T) *T {
    const p: *T = @ptrCast(@alignCast(alloc(@sizeOf(T) + extra, kind)));
    p.* = init;
    return p;
}

pub fn perm(n: usize) *anyopaque {
    const h = calloc(n);
    h.link = @as(usize, @backingInt(Kind.perm)) << 1;
    return body(h);
}

// collection
// ----------------------------------------------------------------
pub fn due() bool {
    return allocated > limit;
}

fn markPtr(p: ?*anyopaque) void {
    const h = header(p orelse return);
    if (kindOf(h) == .perm or isMarked(h)) return;
    h.link |= 1;
    if (kindOf(h) != .str) push(*H, &gray, h);
}

fn markV(v: V) void {
    markPtr(rt.ptr(v));
}

fn drain() void {
    while (gray.pop()) |h| {
        const p = body(h);
        switch (kindOf(h)) {
            .list => for (@as(*rt.Lst, @ptrCast(@alignCast(p))).items()) |v| markV(v),
            .func => {
                const f: *rt.Fn = @ptrCast(@alignCast(p));
                markV(f.d0);
                markV(f.d1);
            },
            .lam => {
                markPtr(@as(*rt.Lam, @ptrCast(@alignCast(p))).env);
            },
            .env => {
                const e: *rt.Env = @ptrCast(@alignCast(p));
                markPtr(e.p);
                for (e.vars) |x| {
                    markPtr(@constCast(x.k));
                    markV(x.v);
                }
            },
            else => {},
        }
    }
}

fn bytesOf(h: *H) usize {
    const p = body(h);
    const n: usize = switch (kindOf(h)) {
        .str => std.mem.len(@as([*:0]const u8, @ptrCast(p))) + 1,
        .list => @sizeOf(rt.Lst) + @as(*rt.Lst, @ptrCast(@alignCast(p))).len * @sizeOf(V),
        .func => @sizeOf(rt.Fn),
        .lam => @sizeOf(rt.Lam),
        .env => @sizeOf(rt.Env) + @as(*rt.Env, @ptrCast(@alignCast(p))).cap * @sizeOf(rt.Var),
        .perm => 0,
    };
    return n + @sizeOf(H);
}

/// Everything the collector starts from: the machine's stacks and running loops, the globals, pinned code values, the error value.
fn markRoots() void {
    rt.env_pools = @splat(null); // recycled scopes are garbage as far as the collector is concerned
    for (rt.ks.items) |k| {
        markPtr(k.e);
        if (k.kind == .loop) markPtr(k.iter_env);
    }
    for (rt.vs.items) |v| markV(v);
    for (rt.machines.items) |m| markPtr(m.e);
    for (rt.gk, rt.gv) |k, v| if (k != null) markV(v);
    for (rt.pins.items) |v| markV(v);
    markV(lang.errv);
}

pub fn collect() void {
    markRoots();
    drain();
    var live: usize = 0;
    var prev: ?*H = null;
    var cur = all;
    while (cur) |h| {
        const next = nextOf(h);
        cur = next;
        if (isMarked(h)) {
            h.link &= ~@as(usize, 1);
            live += bytesOf(h);
            prev = h;
            continue;
        }
        if (prev) |q| setNext(q, next) else all = next;
        if (kindOf(h) == .env) {
            const e: *rt.Env = @ptrCast(@alignCast(body(h)));
            if (e.vars.ptr != after(rt.Var, e)) std.heap.c_allocator.free(e.vars.ptr[0..e.cap]);
        }
        std.c.free(h);
    }
    limit = @max(2 << 20, live / 2); // the heap grows to about 1.5x its live size between collections
    allocated = 0;
}
