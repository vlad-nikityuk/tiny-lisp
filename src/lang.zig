// zig fmt: off
// The compiler, the explicit-stack evaluator and the parser.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const vm = @import("vm.zig");
const V = rt.V; const Node = rt.Node;
pub var out: *std.Io.Writer = undefined;
pub var errv: V = .nil;
// compiler
// ----------------------------------------------------------------
// The AST becomes nodes (rt.Node) once, lazily: a node is compiled when first evaluated, so macros see code in the order it runs.
// Every macro/* runs once per node; a new or redefined one (rt.epoch) recompiles all nodes. Nodes and symbols are permanent; their AST is pinned.
pub var in_macro = false; // while a macro runs, code is not expanded (so expansion nests one level)
const make = rt.make; pub const stub = rt.stub; const kids = rt.kids; const intern = rt.intern; // compiler support code is in runtime.zig
pub fn current() u32 { return rt.epoch *% 2 +% @intFromBool(in_macro) +% 1; } // the stamp of up-to-date code; 0 means not compiled yet
fn expand(x: V) rt.E!V { // every macro/* over x in turn; one that returns a false value leaves x as it was
    in_macro = true;
    defer in_macro = false;
    var y = x;
    for (rt.macros.items) |macro| {
        const b = rt.vs.items.len; defer rt.vs.items.len = b;
        gc.push(V, &rt.vs, macro.*); gc.push(V, &rt.vs, y);
        const z = try exec(.{ .apply = b }, rt.root);
        if (rt.truthy(z)) y = z;
    }
    return y;
}
fn form(a: []const V) rt.E!rt.Code {
    if (a.len == 0) return rt.fail(rt.str("TinyLisp: cannot evaluate an empty list", .{}));
    const head = if (a[0].is(.s)) std.meta.stringToEnum(rt.Form, std.mem.span(a[0].asStr())) orelse .apply else .apply;
    switch (head) {
        .quote => return .{ .val = rt.arg(a, 1) },
        .lambda => {
            const ps = rt.items(rt.arg(a, 1)); const params = make(rt.Key, ps.len); var n: usize = 0; // (a b & rest): rest takes the extra arguments
            const proto = &make(rt.Proto, 1)[0]; proto.* = .{ .params = params[0..0], .body = stub(rt.arg(a, 2)) };
            for (ps) |p| { if (p.is(.s) and std.mem.eql(u8, std.mem.span(p.asStr()), "&")) { proto.rest = true; continue; } const sym = intern(p); if (sym.prim and !sym.local) rt.epoch +%= 1; sym.local = true; params[n] = sym.key; n += 1; proto.params = params[0..n]; }
            return .{ .lambda = proto };
        },
        .@"if" => return .{ .@"if" = kids(a[1..], 3) },
        .begin => return .{ .begin = kids(a[1..], @max(a.len - 1, 1)) }, // (begin) is nil
        .@"&&" => return .{ .@"&&" = kids(a[1..], @max(a.len - 1, 1)) }, .@"||" => return .{ .@"||" = kids(a[1..], @max(a.len - 1, 1)) }, // short-circuit
        .define, .@"set!" => {
            const d = &make(rt.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = stub(rt.arg(a, 2)), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return rt.special(a, kids(a, a.len)),
    }
}
pub fn force(n: *Node) rt.E!void { // expand macros over n's AST, then build its code unless they changed nothing
    const x = if (in_macro or rt.ptr(n.ast) == null) n.ast else try expand(n.ast);
    if (n.code == .raw or x != n.src) {
        n.code = switch (x.tag()) {
            .s => .{ .ref = .{ .sym = intern(x) } },
            .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
            .l => try form(x.asList().items()),
            else => .{ .val = x },
        };
        if (n.code == .lambda) n.code.lambda.guard = n.guard;
        n.src = rt.pin(x);
    }
    n.stamp = current();
}
inline fn leaf(n: *Node, e: *rt.Env) rt.E!?V { // the value if n is a constant or a variable, else null; compiles n on demand
    if (n.stamp != current()) try force(n);
    return switch (n.code) { .val => |v| v, .ref => |*r| rt.fetch(e, r), else => null };
}
inline fn atom(n: *Node, e: *rt.Env) rt.E!?V { // a leaf, or a primitive call on leaves that computes in place (rt.Prim)
    if (try leaf(n, e)) |v| return v;
    return if (n.code == .prim and !n.code.prim.slow) try inplace(n.code.prim, e, 3) else null;
}
fn inplace(p: *rt.Prim, e: *rt.Env, depth: u8) rt.E!?V { // operands may be primitive calls themselves, a few levels deep (so native recursion stays bounded)
    if (p.sym.local or p.g.* != p.f) return null;
    var x = [2]V{ .nil, .nil };
    inline for (0..2) |i| if (i + 1 < p.c.len) { const n = p.c[i + 1]; x[i] = try leaf(n, e) orelse if (n.code == .prim and depth > 0 and !n.code.prim.slow) (try inplace(n.code.prim, e, depth - 1) orelse return null) else { p.slow = true; return null; }; }; // slow: never in place
    return if (p.c.len == 2) rt.fast1(p.op, x[0]) else rt.fast(p.op, x[0], x[1]);
}
// evaluator
// ----------------------------------------------------------------
// No native recursion per call, nesting level or callback: pending work is a frame on rt.ks, a call's values are collected on rt.vs,
// and each step is a rt.Go: evaluate a node, hand a value to the innermost frame, collect operands, or apply vs[b].
pub fn eval(ast: V, env: *rt.Env) rt.E!V { return exec(.{ .eval = stub(ast) }, env); }
fn exec(go: rt.Go, env: *rt.Env) rt.E!V { // run from go until its first step has a value; an error goes to the innermost `try`
    var m: rt.M = .{ .e = env, .base = rt.ks.items.len }; // ks[base..] are this run's frames
    const vbase = rt.vs.items.len; gc.push(*rt.M, &rt.machines, &m); // its scope is a collector root
    defer rt.machines.items.len -= 1;
    errdefer rt.ks.items.len, rt.vs.items.len = .{ m.base, vbase };
    var step = go;
    while (true) return run(&m, step) catch |err| { step = rt.recover(m.base) orelse return err; continue; };
}
fn run(m: *rt.M, go: rt.Go) rt.E!V {
    const ks = &rt.ks;
    const vs = &rt.vs;
    sw: switch (go) {
        .eval => |n| {
            if (!in_macro and gc.due()) gc.collect(); // the safe point: no value lives in a Zig local
            if (try atom(n, m.e)) |v| continue :sw .{ .ret = v };
            switch (n.code) {
                .lambda => |p| continue :sw .{ .ret = rt.lambda(p, m.e) },
                .@"if" => |c| {
                    if (try atom(c[0], m.e)) |v| continue :sw .{ .eval = c[if (rt.truthy(v)) 1 else 2] };
                    _ = rt.frame(.@"if", c, m.e);
                    continue :sw .{ .eval = c[0] };
                },
                .begin => |c| { if (c.len > 1) _ = rt.frame(.begin, c, m.e); continue :sw .{ .eval = c[0] }; },
                .prim => |p| continue :sw .{ .args = .{ .c = p.c, .i = 0, .b = vs.items.len } }, // not computable in place: the plain call
                .@"&&", .@"||" => |c| { if (c.len > 1) _ = rt.frame(if (n.code == .@"&&") .@"&&" else .@"||", c, m.e); continue :sw .{ .eval = c[0] }; },
                .def => |d| { if (try atom(d.val, m.e)) |v| { try rt.assign(d, m.e, v); continue :sw .{ .ret = v }; } rt.frame(.def, &.{}, m.e).d = d; continue :sw .{ .eval = d.val }; },
                .call => |c| continue :sw .{ .args = .{ .c = c, .i = 0, .b = vs.items.len } },
                else => unreachable,
            }
        },
        .vm => |x| { if (!in_macro and gc.due()) gc.collect(); continue :sw try vm.exec(m, x.code, x.pc); },
        .ret => |v| {
            if (ks.items.len == m.base) return v;
            const k = &ks.items[ks.items.len - 1]; const c = k.c;
            if (m.e != k.e) rt.release(m.e); // the call that returned is over
            m.e = k.e;
            switch (k.kind) {
                .@"if" => { ks.items.len -= 1; continue :sw .{ .eval = c[if (rt.truthy(v)) 1 else 2] }; },
                .begin => { k.i += 1; if (k.i == c.len - 1) ks.items.len -= 1; continue :sw .{ .eval = c[k.i] }; }, // the last one is a tail position
                .@"&&", .@"||" => if (rt.truthy(v) == (k.kind == .@"&&")) { k.i += 1; if (k.i == c.len - 1) ks.items.len -= 1; continue :sw .{ .eval = c[k.i] }; } else { ks.items.len -= 1; continue :sw .{ .ret = v }; },
                .def => { try rt.assign(k.d, m.e, v); ks.items.len -= 1; continue :sw .{ .ret = v }; },
                .native => continue :sw try rt.step(k, v),
                .vm => { const code = k.code; const pc = k.i; ks.items.len -= 1; gc.push(V, vs, v); continue :sw .{ .vm = .{ .code = code, .pc = pc } }; },
                .loop => { k.env2 = null; gc.push(V, vs, v); continue :sw .{ .vm = .{ .code = k.code, .pc = k.i } }; }, // the iteration's scope was released above
                .call => { ks.items.len -= 1; try rt.operand(c, k.i, v); continue :sw .{ .args = .{ .c = c, .i = k.i + 1, .b = k.base } }; },
            }
        },
        .args => |a| { // push the function and arguments from a.i on; constants and variables need no frame
            var i = a.i;
            while (i < a.c.len) : (i += 1) {
                const v = try atom(a.c[i], m.e) orelse { const k = rt.frame(.call, a.c, m.e); k.i = i; k.base = a.b; continue :sw .{ .eval = a.c[i] }; };
                try rt.operand(a.c, i, v);
            }
            continue :sw .{ .apply = a.b };
        },
        .apply => |b| {
            const f = vs.items[b]; const args = vs.items[b + 1 ..];
            switch (f.tag()) {
                .lam => { // a tail call: only the new scope stays live
                    const l = f.asLam(); const code = vm.ready(l.proto); // (compiling may expand macros, which runs the machine: take the arguments after it)
                    if (ks.items.len == m.base or ks.items[ks.items.len - 1].e != m.e) rt.release(m.e); // no frame needs the old one
                    m.e = rt.bind(l, vs.items[b + 1 ..]); vs.items.len = b;
                    continue :sw if (code) |c| .{ .vm = .{ .code = c, .pc = 0 } } else .{ .eval = l.proto.body };
                },
                .f => { const n = f.asFn(); switch (n.f) {
                    .plain => |p| { const v = try p(n, args); vs.items.len = b; continue :sw .{ .ret = v }; },
                    .step => continue :sw try rt.start(b, m.e), // a native frame: the arguments stay on vs
                } },
                else => return rt.fail(rt.str("TinyLisp: {f} is not a function", .{f})),
            }
        },
    }
}
// parser
// ----------------------------------------------------------------
// Iterative, so nesting depth is limited by memory only. Symbols and literals are permanent.
var src: []const u8 = ""; var pos: usize = 0; const space = " \t\n\r"; const unexpected = "TinyLisp: Syntax error, unexpected closing parenthesis";
const prefixes = [_][]const u8{ "quote", "quasiquote", "unquote", "unquote-splicing" }; // ' ` ~ ~@

fn peek() u8 { return if (pos < src.len) src[pos] else 0; } // a 0 byte ends the source
fn skip() void {
    while (true) { pos = std.mem.indexOfNonePos(u8, src, pos, space) orelse src.len; if (peek() != ';') return; pos = std.mem.indexOfAnyPos(u8, src, pos, "\n\x00") orelse src.len; }
}
fn lex() V {
    const lit = peek() == '"'; const start = pos + @intFromBool(lit);
    pos = std.mem.indexOfAnyPos(u8, src, start, if (lit) "\"\x00" else space ++ "\x00()'`~;\"") orelse src.len;
    const t = src[start..pos]; if (lit and peek() == '"') pos += 1;
    if (!lit and std.mem.indexOfAny(u8, t, "0123456789") != null) if (std.fmt.parseFloat(f64, t)) |d| return V.num(d) else |_| {};
    const text = rt.mkstr(t, true);
    return if (lit) V.literal(text) else V.string(text);
}

pub fn parse(text: []const u8) rt.E!V {
    src = text; pos = 0;
    var done: std.ArrayList(V) = .empty; defer done.deinit(std.heap.c_allocator); // finished items, the open lists' items among them
    var open: std.ArrayList(i64) = .empty; defer open.deinit(std.heap.c_allocator); // where each open list starts in done; below 0: a prefix, -1 - its index in prefixes
    while (open.items.len > 0 or done.items.len == 0) {
        skip();
        var d: V = switch (peek()) {
            0 => return rt.fail(rt.str("TinyLisp: Syntax error, unbalanced expression", .{})),
            '(' => { pos += 1; gc.push(i64, &open, @intCast(done.items.len)); continue; },
            '\'', '`', '~' => |c| { pos += 1; const k: i64 = if (c == '~' and peek() == '@') 3 else @intCast(std.mem.indexOfScalar(u8, "'`~", c).?); pos += @intFromBool(k == 3); gc.push(i64, &open, -1 - k); continue; },
            ')' => blk: {
                pos += 1; if (open.items.len == 0 or open.getLast() < 0) return rt.fail(rt.str(unexpected, .{}));
                const items = done.items[@intCast(open.pop().?)..]; done.items.len -= items.len;
                break :blk rt.list(items, items.len);
            },
            else => lex(),
        };
        while (open.items.len > 0 and open.getLast() < 0) : (_ = open.pop()) d = rt.list(&.{ V.string(rt.mkstr(prefixes[@intCast(-1 - open.getLast())], true)), d }, 2); // 'x is (quote x)
        gc.push(V, &done, d);
    }
    skip();
    if (peek() != 0) return rt.fail(rt.str(unexpected, .{}));
    return done.items[0];
}
