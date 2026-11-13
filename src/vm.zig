// Tier 2, the executor: runs the bytecode that bytecode.zig compiles, inside the machine of lang.zig. `exec` runs
// instructions until it needs the machine and returns the next rt.Go (a call, or a return); a call that is not a tail call
// leaves a `vm` frame on rt.ks that resumes the code at the instruction after it.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const bc = @import("bytecode.zig");
const prims = @import("primitives.zig");
const lang = @import("lang.zig");
const V = rt.V;
const E = rt.E;
const Op = bc.Opcode;

/// The primitive that an arithmetic instruction computes.
fn primOf(comptime op: Op) rt.Op {
    return switch (op) {
        .add => .@"+",
        .sub => .@"-",
        .mul => .@"*",
        .div => .@"/",
        .mod => .mod,
        .lt => .@"<",
        .gt => .@">",
        .le => .@"<=",
        .ge => .@">=",
        .eq => .@"eq?",
        .at => .at,
        else => unreachable,
    };
}

/// (op x y) with both operands on the stack: replace them by the value, or leave them and say false.
inline fn arith(comptime op: Op, st: [*]V, sp: *usize) bool {
    const n = sp.*;
    st[n - 2] = prims.fast(comptime primOf(op), st[n - 2], st[n - 1]) orelse return false;
    sp.* = n - 1;
    return true;
}

/// The slot of a name that is not one of this function's slots. The first lookup of an instruction notes where the name was found
/// (hops << 16 | index in b); the scopes it passed must have a fixed layout (tier 2), so later lookups go straight there
/// and only check the key.
inline fn outerSlot(e: *rt.Env, ins: *bc.Ins, sym: *rt.Sym, g: *?*V) ?*V {
    if (ins.b != 0 and ins.c == rt.shape) {
        var s = e;
        var hops = ins.b >> 16;
        while (hops > 0) : (hops -= 1) s = s.p.?;
        const i = ins.b & 0xffff;
        if (i < s.vars.len and s.vars[i].k == sym.key) return &s.vars[i].v;
    }
    return outerLook(e, ins, sym, g);
}

noinline fn outerLook(e: *rt.Env, ins: *bc.Ins, sym: *rt.Sym, g: *?*V) ?*V {
    var s = e;
    var hops: u32 = 0;
    var fixed = true; // every scope passed so far is a tier-2 scope
    while (sym.local and s.p != null) : (s = s.p.?) {
        var i = s.vars.len;
        while (i > 0) : (i -= 1) if (s.vars[i - 1].k == sym.key) {
            if (fixed and hops < 0x7fff and i - 1 < 0x10000) {
                ins.b = (hops << 16) | @as(u32, @intCast(i - 1));
                ins.c = rt.shape;
            }
            return &s.vars[i - 1].v;
        };
        fixed = fixed and s.proto != null and s.proto.?.code != null;
        hops += 1;
    }
    if (g.* == null) g.* = rt.slotOf(rt.root, sym.key);
    return g.*;
}

/// An operation on values it does not compute in place: call whatever its name is now (it was a primitive when compiled).
fn slow(m: *rt.Machine, code: *bc.Bytecode, ip: [*]const bc.Ins, arity: usize) E!rt.Go {
    const p = code.prims[ip[0].a];
    const vs = &rt.vs;
    const n = vs.items.len;
    var g: ?*V = null;
    const f = if (rt.find(m.e, p.sym, &g)) |s| s.* else V.nil;
    if (f == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{p.c[0].ast}));
    vs.insert(rt.gpa, n - arity, f) catch gc.oom();
    return call(m, n - arity, code, (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(bc.Ins) + 1);
}

/// Run code from pc until it calls or returns; the next step is the result. The stack of values is rt.vs, with room for the whole
/// function reserved up front, so its top is kept in a local (sp) and rt.vs.items.len is brought up to date only when leaving.
pub noinline fn exec(m: *rt.Machine, code0: *bc.Bytecode, pc0: usize) E!rt.Go {
    const vs = &rt.vs;
    const ks = &rt.ks;
    var e = m.e;
    var code = code0;
    var ip = code.ins.ptr + pc0;
    if (vs.capacity - vs.items.len < code.room) vs.ensureTotalCapacity(rt.gpa, vs.items.len + code.room) catch gc.oom();
    var st = vs.items.ptr;
    var sp = vs.items.len;
    var depth: usize = 0; // loop bodies being run by this call of exec (each has a loop frame under the frames of its calls)
    sw: switch (ip[0].op) {
        .konst => {
            st[sp] = code.consts[ip[0].a];
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .local => {
            st[sp] = e.vars[ip[0].a].v;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .outer => {
            const r = code.refs[ip[0].a];
            st[sp] = if (outerSlot(e, &ip[0], r.sym, &r.g)) |p| p.* else V.nil;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .lambda => {
            st[sp] = rt.lambda(code.protos[ip[0].a], e);
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .setlocal => {
            e.vars[ip[0].a].v = st[sp - 1];
            ip += 1;
            continue :sw ip[0].op;
        },
        .setouter => {
            const d = code.defs[ip[0].a];
            if (d.define) try rt.assign(d, e, st[sp - 1]) else if (outerSlot(e, &ip[0], d.sym.?, &d.g)) |p| {
                if (rt.compiledInto(p.*)) rt.epoch +%= 1; // as rt.assign does
                p.* = st[sp - 1];
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .pop => {
            sp -= 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .jmp => {
            ip = code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .jmpf => {
            sp -= 1;
            ip = if (rt.truthy(st[sp])) ip + 1 else code.ins.ptr + ip[0].b;
            continue :sw ip[0].op;
        },
        .andj, .orj => { // decided (false for &&, true for ||): keep the value and jump; else drop it and go on
            if (rt.truthy(st[sp - 1]) == (ip[0].op == .orj)) ip = code.ins.ptr + ip[0].b else {
                sp -= 1;
                ip += 1;
            }
            continue :sw ip[0].op;
        },
        .not => {
            st[sp - 1] = V.boolean(!rt.truthy(st[sp - 1]));
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .add, .sub, .mul, .mod, .div, .lt, .gt, .le, .ge, .eq, .at => |op| {
            if (!arith(op, st, &sp)) {
                vs.items.len = sp;
                return slow(m, code, ip, 2);
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .vset => { // (vset! list index value): the native itself does anything that is not an in-range store
            const l = st[sp - 3];
            const i = st[sp - 2];
            if (l.is(.l) and i.isNum()) {
                const items = l.asList().items();
                const x = i.asNum();
                if (x >= 0 and x < @as(f64, @floatFromInt(items.len))) {
                    items[@intFromFloat(x)] = st[sp - 1];
                    sp -= 2;
                    st[sp - 1] = items[@intFromFloat(x)];
                    ip += 1;
                    continue :sw ip[0].op;
                }
            }
            const n = code.consts[ip[0].a].asFn();
            vs.items.len = sp;
            const r = try n.f.plain(n, st[sp - 3 .. sp]);
            sp -= 2;
            st[sp - 1] = r;
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .add_lk, .sub_lk, .mul_lk, .lt_lk, .gt_lk, .le_lk, .ge_lk, .eq_lk, .at_lk, .add_ll, .sub_ll, .mul_ll, .lt_ll, .gt_ll, .le_ll, .ge_ll, .eq_ll, .at_ll => |op| {
            const name = comptime @tagName(op);
            const x = e.vars[ip[0].b >> 16].v;
            const y = if (comptime name[name.len - 1] == 'k') code.consts[ip[0].b & 0xffff] else e.vars[ip[0].b & 0xffff].v;
            if (prims.fast(comptime primOf(@field(Op, name[0 .. name.len - 3])), x, y)) |v| {
                st[sp] = v;
                sp += 1;
                ip += 1;
                continue :sw ip[0].op;
            }
            st[sp] = x;
            st[sp + 1] = y;
            vs.items.len = sp + 2;
            return slow(m, code, ip, 2);
        },
        inline .add_sk, .sub_sk, .mul_sk, .lt_sk, .gt_sk, .le_sk, .ge_sk, .eq_sk, .at_sk, .add_sl, .sub_sl, .mul_sl, .lt_sl, .gt_sl, .le_sl, .ge_sl, .eq_sl, .at_sl => |op| { // the first operand is on the stack, the second a constant or a local
            const name = comptime @tagName(op);
            const y = if (comptime name[name.len - 1] == 'k') code.consts[ip[0].b] else e.vars[ip[0].b].v;
            if (prims.fast(comptime primOf(@field(Op, name[0 .. name.len - 3])), st[sp - 1], y)) |v| {
                st[sp - 1] = v;
                ip += 1;
                continue :sw ip[0].op;
            }
            st[sp] = y;
            sp += 1;
            vs.items.len = sp;
            return slow(m, code, ip, 2);
        },
        .vset_ll => { // (vset! list index value) with the list and the index in locals, the value on the stack
            const l = e.vars[ip[0].b >> 16].v;
            const i = e.vars[ip[0].b & 0xffff].v;
            if (l.is(.l) and i.isNum()) {
                const items = l.asList().items();
                const x = i.asNum();
                if (x >= 0 and x < @as(f64, @floatFromInt(items.len))) {
                    items[@intFromFloat(x)] = st[sp - 1];
                    ip += 1;
                    continue :sw ip[0].op;
                }
            }
            const n = code.consts[ip[0].a].asFn();
            const value = st[sp - 1]; // the native does anything that is not an in-range store, and gets all three
            st[sp - 1] = l;
            st[sp] = i;
            st[sp + 1] = value;
            sp += 2;
            vs.items.len = sp;
            const r = try n.f.plain(n, st[sp - 3 .. sp]);
            sp -= 2;
            st[sp - 1] = r;
            ip += 1;
            continue :sw ip[0].op;
        },
        .prim1 => {
            const p = code.prims[ip[0].a];
            const r = prims.fast1(p.op, st[sp - 1]);
            const v = r orelse {
                vs.items.len = sp;
                return slow(m, code, ip, 1);
            };
            st[sp - 1] = v;
            ip += 1;
            continue :sw ip[0].op;
        },
        .call => {
            vs.items.len = sp;
            const b = sp - ip[0].a - 1;
            if (st[b].is(.f)) if (st[b].asFn().f == .plain) { // a native that just computes a value: no need to leave
                const n = st[b].asFn();
                st[b] = try n.f.plain(n, st[b + 1 .. sp]);
                sp = b + 1;
                ip += 1;
                continue :sw ip[0].op;
            };
            if (st[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return call(m, b, code, (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(bc.Ins) + 1);
        },
        .tailcall => {
            const b = sp - ip[0].a - 1;
            const f = st[b];
            if (f.is(.lam)) { // a function calling itself in tail position, in a scope nothing else holds: it runs again in that scope
                const l = f.asLam();
                if (e.proto == l.proto and e.p == l.env and !e.captured and !l.proto.rest) {
                    const np = l.proto.params.len;
                    for (e.vars[0..np], 0..) |*x, i| x.v = if (i < ip[0].a) st[b + 1 + i] else V.nil;
                    for (e.vars[np..code.keys.len]) |*x| x.v = V.nil; // its defines start unbound
                    sp = b;
                    ip = code.ins.ptr;
                    if (gc.due()) {
                        vs.items.len = sp;
                        gc.collect();
                    }
                    continue :sw ip[0].op;
                }
            }
            vs.items.len = sp;
            if (f.is(.f)) if (f.asFn().f == .plain) { // as in a call, and then return its value
                const n = f.asFn();
                const v = try n.f.plain(n, st[b + 1 .. sp]);
                vs.items.len = b;
                return .{ .ret = v };
            };
            if (st[b] == V.nil) return rt.fail(rt.str("TinyLisp: Function {f} is not defined", .{code.consts[ip[0].b]}));
            return .{ .apply = b };
        },
        .ret => {
            if (depth > 0) { // the body of a loop run here is done: back to the loop, which keeps its frame
                depth -= 1;
                const k = ks.items[ks.items.len - 1];
                const v = st[sp - 1];
                e = k.e;
                m.e = e;
                code = k.code;
                ip = code.ins.ptr + k.i;
                sp = k.base;
                st[sp] = v;
                sp += 1;
                continue :sw ip[0].op;
            }
            vs.items.len = sp - 1;
            return .{ .ret = st[sp - 1] };
        },
        .each => { // the list is on the stack: add the index and a place for the body's value
            st[sp] = V.num(-1);
            st[sp + 1] = V.nil;
            sp += 2;
            ip += 1;
            continue :sw ip[0].op;
        },
        .map => { // as each, with the list of results (the body's values) between the index and that place
            st[sp] = V.num(-1);
            st[sp + 1] = rt.list(&.{}, if (ip[0].b != 0) rt.rangeLen(st[sp - 1]) else rt.items(st[sp - 1]).len);
            st[sp + 2] = V.nil;
            sp += 3;
            ip += 1;
            continue :sw ip[0].op;
        },
        .global => { // a name of an inlined function's body: only the global scope is looked at
            const r = code.refs[ip[0].a];
            if (r.g == null) r.g = rt.slotOf(rt.root, r.sym.key);
            st[sp] = if (r.g) |p| p.* else V.nil;
            sp += 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        .setglobal => {
            const d = code.defs[ip[0].a];
            if (d.g == null) d.g = rt.slotOf(rt.root, d.sym.?.key);
            if (d.g) |p| {
                if (rt.compiledInto(p.*)) rt.epoch +%= 1;
                p.* = st[sp - 1];
            }
            ip += 1;
            continue :sw ip[0].op;
        },
        .storelocal => {
            e.vars[ip[0].a].v = st[sp - 1];
            sp -= 1;
            ip += 1;
            continue :sw ip[0].op;
        },
        inline .eachnext, .mapnext => |op| { // [list, index, (results,) body value]: the next iteration, or the end of the loop
            const is_map = op == .mapnext;
            const top = sp - 1;
            const ib = if (is_map) top - 2 else top - 1; // the index
            const idx = st[ib].asNum() + 1;
            const counted = ip[0].b != 0;
            const items = rt.items(st[ib - 1]);
            const len = if (counted) rt.rangeLen(st[ib - 1]) else items.len;
            if (is_map and idx > 0) st[ib + 1].asList().items()[@intFromFloat(idx - 1)] = st[top];
            if (idx >= @as(f64, @floatFromInt(len))) { // done: the value of the loop is nil (each) or the results (map)
                if (idx > 0) { // there is a loop frame
                    const k = &ks.items[ks.items.len - 1];
                    if (k.iter_env) |x| if (!x.captured) rt.release(x);
                    ks.items.len -= 1;
                }
                st[ib - 1] = if (is_map) st[ib + 1] else V.nil;
                sp = ib;
                ip += 1;
                continue :sw ip[0].op;
            }
            if (idx == 0) {
                const k = rt.frame(.loop, &.{}, e);
                k.i = (@intFromPtr(ip) - @intFromPtr(code.ins.ptr)) / @sizeOf(bc.Ins);
                k.base = top;
                k.code = code;
            }
            const k = &ks.items[ks.items.len - 1];
            st[ib] = V.num(idx);
            if (!lang.in_macro and gc.due()) {
                vs.items.len = sp;
                gc.collect();
            }
            const body = code.bodies[ip[0].a].?;
            const item = if (counted) V.num(idx) else items[@intFromFloat(idx)];
            if (k.iter_env) |x| if (!x.captured and x.vars.len == body.keys.len) { // nothing holds the scope of the last iteration: use it again
                x.vars[0].v = item;
                for (x.vars[1..]) |*v| v.v = V.nil;
                e = x;
            } else {
                k.iter_env = null;
                var lam: rt.Lam = .{ .proto = code.protos[ip[0].a], .env = e };
                e = rt.bindWith(&lam, &.{item}, body);
            } else {
                var lam: rt.Lam = .{ .proto = code.protos[ip[0].a], .env = e };
                e = rt.bindWith(&lam, &.{item}, body);
            }
            k.iter_env = e;
            m.e = e;
            depth += 1;
            code = body;
            ip = code.ins.ptr;
            sp = top;
            if (vs.capacity < top + code.room) {
                vs.items.len = sp;
                vs.ensureTotalCapacity(rt.gpa, top + code.room) catch gc.oom();
                st = vs.items.ptr;
            }
            continue :sw ip[0].op;
        },
    }
}

/// A call that is not a tail call: leave a frame that resumes at pc with the value pushed.
fn call(m: *rt.Machine, b: usize, code: *bc.Bytecode, pc: usize) rt.Go {
    const k = rt.frame(.vm, &.{}, m.e);
    k.i = pc;
    k.base = b;
    k.code = code;
    return .{ .apply = b };
}
