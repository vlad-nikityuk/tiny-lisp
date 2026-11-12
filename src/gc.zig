// Lean GC: reference counts for heap references only, plus per-call allocation regions.
//
// 1. Every allocation is appended to a log. A frame remembers the log position when it starts (its mark).
// 2. Locals, frames and the operand stack are NOT counted. Only values stored in the heap (list items, scope
//    slots, globals, closure captures, native data) are: `ret` on store, `rel` on overwrite.
// 3. When a frame finishes it sweeps its region: everything allocated since the mark with a zero count is freed,
//    except the returned value, which stays in the log and joins the caller's region.
// 4. Tail calls and the trampoline resweep the same region each iteration; long-lived survivors move to the
//    enclosing region so loops stay linear.
//
// Limitation: reference cycles (a closure stored in the scope it captures) are never freed.
const std = @import("std");
const lisp = @import("runtime.zig");
const V = lisp.V;

pub const Kind = enum(i16) { dead = -2, perm = -1, str, list, func, lam, env };
const H = extern struct { rc: i32 = 0, kind: Kind, age: i16 = 0, idx: usize = 0 }; // header in front of every managed object; age: loop sweeps survived
const old = 4; // loop sweeps an object must survive before it's treated as long-lived (values passed along a loop live ~2)

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

/// A managed T initialised to init, with `extra` bytes after it.
pub fn new(comptime T: type, extra: usize, kind: Kind, init: T) *T {
    const p: *T = @ptrCast(@alignCast(alloc(@sizeOf(T) + extra, kind)));
    p.* = init;
    return p;
}

pub fn perm(n: usize) *anyopaque {
    const h = calloc(n);
    h.* = .{ .kind = .perm, .rc = 1 << 30 };
    return body(h);
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
            for (e.vars) |x| {
                rel(@ptrCast(@constCast(x.k)));
                rel(lisp.ptr(x.v));
            }
            if (e.vars.ptr != after(lisp.Var, e)) std.heap.c_allocator.free(e.vars.ptr[0..e.cap]);
        },
        else => {},
    }
    std.c.free(h);
}

pub fn mark() usize {
    return log.items.len;
}

fn isOld(h: *H, loop: bool) bool {
    return loop and h.rc > 0 and h.age >= old;
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
    // every iteration: survivors that are heap-referenced and already lived through old loop sweeps are long-lived, so they go first
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
    if (loop) for (log.items[young..j]) |h| if (h.?.age < old) {
        h.?.age += 1;
    };
    log.items.len = j;
    return young;
}

/// Sweep the region starting at m, keeping (and returning) the value being handed to the caller.
pub fn sweepKeep(m: usize, keep: V) V {
    _ = sweep(m, keep, null, false);
    return keep;
}

/// For loops: returns the mark to sweep from next time.
pub fn resweep(m: usize, keep: V, keep2: ?*anyopaque) usize {
    return sweep(m, keep, keep2, true);
}
