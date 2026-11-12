// Memory management: reference counts for heap references + per-call allocation regions.
//
// Only references stored in the heap are counted: list elements, scope slots, globals, closure
// captures and native-closure data. References held in locals are not, which keeps eval free of
// inc/dec bookkeeping. Instead every allocation is appended to a log, and each eval/call remembers
// the log position when it started (mark). When it finishes (sweep) everything allocated since
// then with a zero count is freed, except the value being returned, which simply stays in the log
// and so becomes part of the caller's region. Scopes are ordinary objects: a scope that no closure
// captured has a zero count and is freed as soon as its call returns.
//
// Limitation: reference cycles (e.g. a closure stored in the scope it captures) are never freed.
const std = @import("std");
const lisp = @import("lisp.zig");
const V = lisp.V;

pub const Kind = enum(i16) { dead = -2, perm = -1, str, list, func, lam, env };
const H = extern struct { rc: i32 = 0, kind: Kind, age: i16 = 0, idx: usize = 0 }; // header in front of every managed object; age: loop sweeps survived
const OLD = 4; // loop sweeps an object must survive before it's treated as long-lived (values passed along a loop live ~2)

var log: std.ArrayList(?*H) = .empty;
var dying: std.ArrayList(*H) = .empty; // freed via a worklist, never recursively
var sweep_from: usize = 0;
var keep_a: ?*anyopaque = null;
var keep_b: ?*anyopaque = null;
var sweeping = false;

pub fn oom() noreturn {
    std.debug.print("ToyLisp: out of memory\n", .{});
    std.process.exit(1);
}

pub fn push(comptime T: type, list: *std.ArrayList(T), x: T) void {
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

pub fn alloc(n: usize, kind: Kind) *anyopaque {
    const h = calloc(n);
    h.* = .{ .kind = kind, .idx = log.items.len };
    push(?*H, &log, h);
    return body(h);
}

pub fn new(comptime T: type, extra: usize, kind: Kind) *T {
    return @ptrCast(@alignCast(alloc(@sizeOf(T) + extra, kind)));
}

/// Never freed: parser symbols/literals, root keys, the root scope.
pub fn perm(n: usize) *anyopaque {
    const h = calloc(n);
    h.* = .{ .kind = .perm, .rc = 1 << 30 };
    return body(h);
}

/// Buffers owned by one object (grown scope arrays).
pub fn raw(n: usize) *anyopaque {
    return std.c.malloc(n) orelse oom();
}

pub fn rawFree(p: *anyopaque) void {
    std.c.free(p);
}

/// Count a heap reference.
pub fn ret(p: ?*anyopaque) void {
    if (p) |q| header(q).rc += 1;
}

fn doom(h: *H) void { // queue for freeing
    log.items[h.idx] = null;
    push(*H, &dying, h);
}

/// Drop a heap reference; while sweeping, objects of the region that hit zero are freed too.
pub fn rel(p: ?*anyopaque) void {
    const q = p orelse return;
    const h = header(q);
    h.rc -= 1;
    if (h.rc <= 0 and sweeping and @backingInt(h.kind) >= 0 and h.idx >= sweep_from and log.items[h.idx] == h and q != keep_a and q != keep_b) doom(h);
}

fn freeObj(h: *H) void {
    const p = body(h);
    const kind = h.kind;
    h.kind = .dead;
    switch (kind) {
        .list => for (@as(*lisp.Lst, @ptrCast(@alignCast(p))).a) |v| rel(lisp.ptr(v)),
        .func => {
            const f: *lisp.Fn = @ptrCast(@alignCast(p));
            rel(lisp.ptr(f.d0));
            rel(lisp.ptr(f.d1));
        },
        .lam => {
            const l: *lisp.Lam = @ptrCast(@alignCast(p));
            rel(lisp.ptr(l.params));
            rel(lisp.ptr(l.body));
            rel(l.env);
        },
        .env => {
            const e: *lisp.Env = @ptrCast(@alignCast(p));
            rel(e.p);
            for (e.k[0..e.n], e.v[0..e.n]) |k, v| {
                rel(@ptrCast(@constCast(k)));
                rel(lisp.ptr(v));
            }
            if (e.v != after(V, e)) rawFree(e.v);
        },
        else => {},
    }
    std.c.free(h);
}

pub fn mark() usize {
    return log.items.len;
}

fn isOld(h: *H, loop: bool) bool {
    return loop and h.rc > 0 and h.age >= OLD;
}

/// Free everything allocated since m that nothing references (except keep/keep2).
fn sweep(m: usize, keep: V, keep2: ?*anyopaque, loop: bool) usize {
    if (log.items.len == m) return m;
    sweep_from = m;
    keep_a = lisp.ptr(keep);
    keep_b = keep2;
    sweeping = true;
    for (m..log.items.len) |i| {
        if (log.items[i]) |h| if (h.rc <= 0 and body(h) != keep_a and body(h) != keep_b) doom(h);
        while (dying.pop()) |d| freeObj(d);
    }
    sweeping = false;
    // Survivors stay in the log and so join the caller's region. In a loop (tail calls, trampoline) the same region is swept again
    // every iteration: survivors that are heap-referenced and already lived through OLD loop sweeps are long-lived, so they go first
    // and the returned mark leaves them to the enclosing region instead of rescanning them every iteration (that would be quadratic).
    var j = m;
    for (0..2) |pass| {
        for (m..log.items.len) |i| if (log.items[i]) |h| if (isOld(h, loop) == (pass == 0)) {
            log.items[i] = null;
            h.idx = j;
            log.items[j] = h;
            j += 1;
        };
    }
    var young = j;
    for (m..j) |i| if (!isOld(log.items[i].?, loop)) {
        young = i;
        break;
    };
    if (loop) for (log.items[young..j]) |h| if (h.?.age < OLD) {
        h.?.age += 1;
    };
    log.items.len = j;
    return young;
}

/// Sweep the region starting at m, keeping (and returning) the value being handed to the caller.
pub fn sweepKeep(m: usize, keep: V, keep2: ?*anyopaque) V {
    _ = sweep(m, keep, keep2, false);
    return keep;
}

/// For loops: returns the mark to sweep from next time.
pub fn resweep(m: usize, keep: V, keep2: ?*anyopaque) usize {
    return sweep(m, keep, keep2, true);
}
