// The machine loop: an explicit stack of frames (machine.ks) and of values (machine.vs), with no native recursion per call, nesting level or
// callback. Each step is a machine.Go: run bytecode (vm/exec.zig, which runs until it needs a call or a return), hand a value to the
// innermost frame, or apply the function at vs[b] to the arguments after it.
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const machine = @import("../runtime/machine.zig");
const compiler = @import("../vm/compiler.zig");
const vm = @import("../vm/exec.zig");
const V = value.V;

/// Run from go until its first step has a value; an error goes to the innermost `try`.
pub fn exec(go: machine.Go, env: *scope.Env) value.E!V {
    const vbase = machine.vs.items.len;
    // vbase lets call/cc capture the value suffix belonging to this run (continuation.zig).
    var m: machine.Machine = .{ .e = env, .base = machine.ks.items.len, .vbase = vbase };
    gc.push(*machine.Machine, &machine.machines, &m); // its scope is a collector root
    defer machine.machines.items.len -= 1;
    errdefer machine.ks.items.len, machine.vs.items.len = .{ m.base, vbase };
    var step = go;
    while (true) return run(&m, step) catch |err| {
        step = machine.recover(m.base) orelse return err;
        continue;
    };
}

fn run(m: *machine.Machine, go: machine.Go) value.E!V {
    const ks = &machine.ks;
    const vs = &machine.vs;
    sw: switch (go) {
        .vm => |x| {
            if (gc.due()) gc.collect(); // all live managed values are rooted
            continue :sw try vm.exec(m, x.code, x.pc);
        },
        .ret => |v| {
            if (ks.items.len == m.base) return v;
            const k = &ks.items[ks.items.len - 1];
            if (m.e != k.e) scope.release(m.e); // the call that returned is over
            m.e = k.e;
            switch (k.kind) {
                .native => continue :sw try machine.step(k, v),
                .vm => {
                    const code = k.code;
                    const pc = k.i;
                    ks.items.len -= 1;
                    gc.push(V, vs, v);
                    continue :sw .{ .vm = .{ .code = code, .pc = pc } };
                },
                .loop => {
                    k.iter_env = null; // the iteration's scope was released above
                    gc.push(V, vs, v);
                    continue :sw .{ .vm = .{ .code = k.code, .pc = k.i } };
                },
            }
        },
        .apply => |b| {
            const f = vs.items[b];
            const args = vs.items[b + 1 ..];
            switch (f.tag()) {
                .lam => { // a tail call: only the new scope stays live
                    const l = f.asLam();
                    const code = compiler.ready(l.proto); // (compiling a body does not run Lisp; the arguments are still taken after it)
                    if (ks.items.len == m.base or ks.items[ks.items.len - 1].e != m.e) scope.release(m.e); // no frame needs the old one
                    m.e = scope.bind(l, args);
                    vs.items.len = b;
                    continue :sw .{ .vm = .{ .code = code, .pc = 0 } };
                },
                .f => {
                    const n = f.asFn();
                    switch (n.f) {
                        .plain => |p| {
                            const v = try p(n, args);
                            vs.items.len = b;
                            continue :sw .{ .ret = v };
                        },
                        .step => continue :sw try machine.start(b, m.e), // a native frame: the arguments stay on vs
                    }
                },
                else => return value.fail(value.str("TinyLisp: {f} is not a function", .{f})),
            }
        },
    }
}
