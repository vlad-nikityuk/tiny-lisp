// zig fmt: off
// The compiler, the explicit-stack evaluator and the parser.
const std = @import("std");
const gc = @import("gc.zig");
const rt = @import("runtime.zig");
const V = rt.V; const Node = rt.Node;
pub var out: *std.Io.Writer = undefined;
pub var errv: V = .nil;
// compiler
// ----------------------------------------------------------------
// The AST becomes nodes (rt.Node) once, lazily: a node is compiled when first evaluated, so macros see code in the order it
// runs. Every macro/* runs once per node; a new or redefined one (rt.epoch) makes all nodes compile again. Nodes and symbols
// are permanent; the AST they came from is pinned (rt.pin).
var in_macro = false; // while a macro runs, code is not expanded (so expansion nests one level)
var interned: std.StringHashMapUnmanaged(*rt.Sym) = .empty;

fn make(comptime T: type, n: usize) []T { return @as([*]T, @ptrCast(@alignCast(gc.perm(n * @sizeOf(T)))))[0..n]; }

fn intern(v: V) *rt.Sym { // equal names are the same symbol, so scopes compare keys by address
    const name = std.mem.span(if (v.is(.s)) v.asStr() else rt.str("{f}", .{v}).asStr());
    const entry = interned.getOrPut(std.heap.c_allocator, name) catch gc.oom();
    if (!entry.found_existing) { // the table's key is the symbol's own name
        entry.value_ptr.* = &make(rt.Sym, 1)[0]; entry.value_ptr.*.* = .{ .key = rt.mkstr(name, true) }; entry.key_ptr.* = std.mem.span(entry.value_ptr.*.key);
    }
    return entry.value_ptr.*;
}

pub fn stub(v: V) *Node { const n = &make(Node, 1)[0]; n.* = .{ .ast = rt.pin(v) }; return n; }
fn kids(a: []const V, n: usize) []const *Node { // n nodes for the items of a, nil for missing ones
    const c = make(*Node, n);
    for (c, 0..) |*x, i| x.* = stub(rt.arg(a, i));
    return c;
}
fn current() u32 { return rt.epoch *% 2 +% @intFromBool(in_macro) +% 1; } // the stamp of up-to-date code; 0 means not compiled yet

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
            for (ps) |p| { if (p.is(.s) and std.mem.eql(u8, std.mem.span(p.asStr()), "&")) { proto.rest = true; continue; } const sym = intern(p); sym.local = true; params[n] = sym.key; n += 1; proto.params = params[0..n]; }
            return .{ .lambda = proto };
        },
        .@"if" => return .{ .@"if" = kids(a[1..], 3) },
        .begin => return .{ .begin = kids(a[1..], @max(a.len - 1, 1)) }, // (begin) is nil
        .define, .@"set!" => {
            const d = &make(rt.Def, 1)[0];
            d.* = .{ .sym = if (a.len > 1) intern(a[1]) else null, .val = stub(rt.arg(a, 2)), .define = head == .define };
            return .{ .def = d };
        },
        .apply => return .{ .call = kids(a, a.len) },
    }
}
fn force(n: *Node) rt.E!void { // expand macros over n's AST, then build its code unless they changed nothing
    const x = if (in_macro or rt.ptr(n.ast) == null) n.ast else try expand(n.ast);
    if (n.code == .raw or x != n.src) {
        n.code = switch (x.tag()) {
            .s => .{ .ref = .{ .sym = intern(x) } },
            .lit => .{ .val = V.string(x.asStr()) }, // a string literal evaluates to a string
            .l => try form(x.asList().items()),
            else => .{ .val = x },
        };
        n.src = rt.pin(x);
    }
    n.stamp = current();
}
fn atom(n: *Node, e: *rt.Env) rt.E!?V { // the value if n is a constant or a variable, else null; compiles n on demand
    if (n.stamp != current()) try force(n);
    return switch (n.code) { .val => |v| v, .ref => |*r| rt.fetch(e, r), else => null };
}
// evaluator
// ----------------------------------------------------------------
// No native recursion per call, nesting level or callback: pending work is a frame on rt.ks, a call's values are collected on
// rt.vs, and each step is a rt.Go: evaluate a node, hand a value to the innermost frame, collect operands, or apply vs[b].
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
                .def => |d| { rt.frame(.def, &.{}, m.e).d = d; continue :sw .{ .eval = d.val }; },
                .call => |c| continue :sw .{ .args = .{ .c = c, .i = 0, .b = vs.items.len } },
                else => unreachable,
            }
        },
        .ret => |v| {
            if (ks.items.len == m.base) return v;
            const k = &ks.items[ks.items.len - 1]; const c = k.c;
            if (m.e != k.e) rt.release(m.e); // the call that returned is over
            m.e = k.e;
            switch (k.kind) {
                .@"if" => { ks.items.len -= 1; continue :sw .{ .eval = c[if (rt.truthy(v)) 1 else 2] }; },
                .begin => { k.i += 1; if (k.i == c.len - 1) ks.items.len -= 1; continue :sw .{ .eval = c[k.i] }; }, // the last one is a tail position
                .def => { try rt.assign(k.d, m.e, v); ks.items.len -= 1; continue :sw .{ .ret = v }; },
                .native => continue :sw try rt.step(k, v),
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
                    const l = f.asLam();
                    if (ks.items.len == m.base or ks.items[ks.items.len - 1].e != m.e) rt.release(m.e); // no frame needs the old one
                    m.e = rt.bind(l, args); vs.items.len = b;
                    continue :sw .{ .eval = l.proto.body };
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
