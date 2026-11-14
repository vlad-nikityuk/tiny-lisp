// call-with-current-continuation: capture copies the current run's frames and value stack; invoking abandons
// the running computation and resumes from the snapshot, as if call/cc had returned the argument.
const machine = @import("machine.zig");
const gc = @import("gc.zig");
const scope = @import("scope.zig");
const value = @import("value.zig");
const V = value.V;
const E = value.E;
const Fn = value.Fn;
const Frame = machine.Frame;
const Go = machine.Go;

pub const invokeCont: *const fn (*Fn, *Frame, ?V) E!Go = contInvoke;

const Snap = struct {
    kbase: usize,
    vbase: usize,
    nframes: usize,
    nvalues: usize,
    frames: []Frame,
    values: []V,
};

const hdr = 4 * @sizeOf(usize);

fn snap(f: *Fn) Snap {
    const p: [*]u8 = @ptrCast(@alignCast(f));
    const kbase: usize = @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn)))).*;
    const vbase: usize = @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + @sizeOf(usize)))).*;
    const nframes: usize = @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + 2 * @sizeOf(usize)))).*;
    const nvalues: usize = @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + 3 * @sizeOf(usize)))).*;
    const frames: [*]Frame = @ptrCast(@alignCast(p + @sizeOf(Fn) + hdr));
    const values: [*]V = @ptrCast(@alignCast(p + @sizeOf(Fn) + hdr + nframes * @sizeOf(Frame)));
    return .{
        .kbase = kbase,
        .vbase = vbase,
        .nframes = nframes,
        .nvalues = nvalues,
        .frames = frames[0..nframes],
        .values = values[0..nvalues],
    };
}

fn holdFrames(frames: []const Frame) void {
    for (frames) |k| {
        scope.hold(k.e);
        if (k.iter_env) |env| scope.hold(env);
    }
}

fn macroBoundary() E!void {
    if (machine.machines.items.len > 1 or machine.macro_depth > 0)
        return value.fail(value.str("TinyLisp: a continuation cannot cross a macro expansion", .{}));
}

fn capture(m: *machine.Machine, cc: *const Frame) E!V {
    const ks = &machine.ks;
    const vs = &machine.vs;
    const nframes = ks.items.len - m.base - 1; // below the call/cc frame (zero after a tail call)
    const nvalues = cc.base -| m.vbase; // as if call/cc had returned: the native stack is not kept
    const extra = hdr + nframes * @sizeOf(Frame) + nvalues * @sizeOf(V);
    const f = gc.new(Fn, extra, .func, .{ .f = .{ .step = invokeCont }, .d0 = .nil, .d1 = .nil });
    const p: [*]u8 = @ptrCast(@alignCast(f));
    @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn)))).* = m.base;
    @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + @sizeOf(usize)))).* = m.vbase;
    @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + 2 * @sizeOf(usize)))).* = nframes;
    @as(*usize, @ptrCast(@alignCast(p + @sizeOf(Fn) + 3 * @sizeOf(usize)))).* = nvalues;
    const frames: [*]Frame = @ptrCast(@alignCast(p + @sizeOf(Fn) + hdr));
    const vals: [*]V = @ptrCast(@alignCast(p + @sizeOf(Fn) + hdr + nframes * @sizeOf(Frame)));
    const saved = ks.items[m.base .. ks.items.len - 1];
    @memcpy(frames[0..nframes], saved);
    @memcpy(vals[0..nvalues], vs.items[m.vbase..][0..nvalues]);
    holdFrames(saved);
    return V.fnOf(f);
}

fn callCc(_: *Fn, k: *Frame, v: ?V) E!Go {
    if (v) |r| return machine.finish(k, r);
    try macroBoundary();
    const f = machine.frameArgs(k, 1)[0];
    if (!f.is(.lam) and !f.is(.f)) return value.fail(value.str("TinyLisp: call-with-current-continuation needs a function", .{}));
    const m = machine.machines.getLast();
    const cont = try capture(m, k);
    return machine.callback(f, &.{cont});
}

fn contInvoke(s: *Fn, k: *Frame, v: ?V) E!Go {
    if (v != null) return machine.finish(k, v.?);
    try macroBoundary();
    const m = machine.machines.getLast();
    const snap_info = snap(s);
    if (m.base != snap_info.kbase) {
        value.errv = V.string(value.mkstr("TinyLisp: this continuation cannot be invoked here", false));
        return error.Lisp;
    }
    const args = machine.vs.items[k.base + 1 ..];
    const delivered: V = switch (args.len) {
        0 => .nil,
        1 => args[0],
        else => return value.fail(value.str("TinyLisp: a continuation takes one value", .{})),
    };
    machine.ks.items.len = snap_info.kbase;
    machine.vs.items.len = snap_info.vbase;
    machine.vs.appendSlice(value.gpa, snap_info.values) catch gc.oom();
    for (snap_info.frames) |fr| gc.push(Frame, &machine.ks, fr);
    if (snap_info.frames.len > 0) m.e = machine.ks.items[machine.ks.items.len - 1].e;
    return .{ .ret = delivered };
}

pub fn markCont(f: *Fn) void {
    const step = switch (f.f) {
        .step => |s| s,
        else => return,
    };
    if (step != invokeCont) return;
    const s = snap(f);
    for (s.frames) |k| {
        gc.markPtr(k.e);
        if (k.iter_env) |e| gc.markPtr(e);
    }
    for (s.values) |x| gc.markV(x);
}

pub fn contExtraBytes(f: *Fn) usize {
    const step = switch (f.f) {
        .step => |s| s,
        else => return 0,
    };
    if (step != invokeCont) return 0;
    const s = snap(f);
    return 2 * @sizeOf(usize) + s.nframes * @sizeOf(Frame) + s.nvalues * @sizeOf(V);
}

pub fn install(e: *scope.Env) void {
    const cc = V.fnOf(value.nf(.{ .step = callCc }, .nil, .nil));
    scope.set(e, "call-with-current-continuation", cc);
    scope.set(e, "call/cc", cc);
}
