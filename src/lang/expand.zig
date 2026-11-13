// The expander: before a top-level form is compiled or run, the macros are run over all of it (the bodies of its lambdas too), and
// `defmacro` forms are carried out. So a form is read, expanded, then run, one at a time; a macro defined by one form is in
// effect for the next, and redefining it changes only the forms that follow.
// It needs eval.zig: a macro is a Lisp function, called on a nested machine (macro bodies run during expansion only; running a form
// never nests a machine).
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const scope = @import("../runtime/scope.zig");
const machine = @import("../runtime/machine.zig");
const compile = @import("compile.zig");
const eval = @import("eval.zig");
const V = value.V;

/// Expand x, then run it in e: what happens to each form the REPL, a file or `eval` reads.
pub fn run(x: V, e: *scope.Env) value.E!V {
    return eval.exec(.{ .eval = compile.stub(try form(x, true)) }, e);
}

fn sym(name: []const u8) V {
    return V.string(value.mkstr(name, true));
}

fn headIs(items: []const V, name: []const u8) bool {
    return items.len > 0 and items[0].is(.s) and std.mem.eql(u8, std.mem.span(items[0].asStr()), name);
}

/// Call the macro f on the parts of a form.
fn call(f: V, parts: []const V) value.E!V {
    const b = machine.vs.items.len;
    defer machine.vs.items.len = b;
    gc.push(V, &machine.vs, f);
    machine.vs.appendSlice(value.gpa, parts) catch gc.oom();
    return eval.exec(.{ .apply = b }, scope.root);
}

/// (defmacro name (params) body...): the macro is `(lambda (params) (begin body...))`, expanded and made right now, and kept
/// under its name. The form itself becomes `(quote name)`.
fn defmacro(items: []const V) value.E!V {
    const name = value.arg(items, 1);
    if (!name.is(.s)) return value.fail(value.str("TinyLisp: defmacro needs a name", .{}));
    const text = std.mem.span(name.asStr());
    if (compile.isSpecial(text)) return value.fail(value.str("TinyLisp: {s} is a special form, it cannot be a macro", .{text}));
    const body = if (items.len > 3) items[3..] else &.{};
    const b = machine.vs.items.len;
    gc.push(V, &machine.vs, sym("begin"));
    machine.vs.appendSlice(value.gpa, body) catch gc.oom();
    const code = if (body.len == 1) body[0] else value.list(machine.vs.items[b..], body.len + 1);
    machine.vs.items.len = b;
    const lambda = gc.pin(value.list(&.{ sym("lambda"), value.arg(items, 2), code }, 3));
    const f = try eval.exec(.{ .eval = compile.stub(try form(lambda, false)) }, scope.root);
    if (!f.is(.lam)) return value.fail(value.str("TinyLisp: defmacro {s} needs a parameter list and a body", .{text}));
    const entry = scope.macros.getOrPut(value.gpa, text) catch gc.oom();
    if (!entry.found_existing) entry.key_ptr.* = std.mem.span(value.mkstr(text, true));
    entry.value_ptr.* = f;
    return value.list(&.{ sym("quote"), name }, 2);
}

/// Replace x by what its macro makes of it, again and again, until its head is no macro. Also here: defmacro, which is only
/// allowed where `top` says the form is at top level.
fn head(x0: V, top: bool) value.E!V {
    var x = x0;
    while (x.is(.l)) {
        const items = x.asList().items();
        if (items.len == 0 or !items[0].is(.s) or headIs(items, "quote")) return x;
        if (headIs(items, "defmacro")) {
            if (!top) return value.fail(value.str("TinyLisp: defmacro is only allowed at top level", .{}));
            return defmacro(items);
        }
        const macro = scope.macros.get(std.mem.span(items[0].asStr())) orelse return x;
        x = gc.pin(try call(macro, items[1..]));
    }
    return x;
}

/// A list being rebuilt: the list itself is on machine.vs (a macro may change what else refers to it, and the collector must not free it
/// while it is walked), then its parts so far, from `base` on. top: its parts are top-level forms; form_top: the list itself is.
/// op: its operator is a form and is being expanded first, alone: if that changes it, the list is dispatched again (it may now be a
/// macro call, a quote, a lambda, a begin ...) before any operand is looked at.
const Walk = struct { items: []const V, list: V, i: usize, base: usize, top: bool, form_top: bool, op: bool };

/// x with every macro call in it expanded. `top`: x is a top-level form, so defmacro is allowed in it, and in the parts of a
/// begin that is one. The parts are walked with an explicit stack (the nesting is not limited), and a list none of whose parts
/// changed stays as it is. The form, the macros' results and the parts finished so far are all reachable for the collector
/// (pinned, or on machine.vs), because a macro runs Lisp.
pub fn form(x0: V, top: bool) value.E!V {
    const vs = &machine.vs;
    const base = vs.items.len;
    defer vs.items.len = base;
    var walks: std.ArrayList(Walk) = .empty;
    defer walks.deinit(value.gpa);
    var x = gc.pin(x0);
    var is_top = top;
    while (true) {
        x = try head(x, is_top);
        const items = value.items(x);
        if (items.len > 0 and !headIs(items, "quote")) { // a form with parts to expand; (lambda (params) ...) keeps its parameters
            const kept: usize = if (headIs(items, "lambda") and items.len > 1) 2 else 0;
            gc.push(V, vs, x);
            gc.push(Walk, &walks, .{ .items = items, .list = x, .i = kept, .base = vs.items.len, .top = is_top and headIs(items, "begin"), .form_top = is_top, .op = items[0].is(.l) });
            vs.appendSlice(value.gpa, items[0..kept]) catch gc.oom();
        } else if (walks.items.len == 0) {
            return x;
        } else gc.push(V, vs, x);
        while (true) { // the next part to expand, or the list that is complete
            const w = &walks.items[walks.items.len - 1];
            if (w.op and w.i == 1) { // the operator is done (it is the last part on vs)
                w.op = false;
                const op = vs.items[vs.items.len - 1];
                if (op != w.items[0]) {
                    vs.appendSlice(value.gpa, w.items[1..]) catch gc.oom();
                    const again = gc.pin(value.list(vs.items[w.base..], w.items.len));
                    is_top = w.form_top;
                    vs.items.len = w.base - 1;
                    walks.items.len -= 1;
                    x = again;
                    break;
                }
            }
            if (w.i < w.items.len) {
                x = w.items[w.i];
                is_top = w.top;
                w.i += 1;
                break;
            }
            const parts = vs.items[w.base..];
            const done = if (std.mem.eql(V, parts, w.items)) w.list else gc.pin(value.list(parts, parts.len));
            vs.items.len = w.base - 1;
            walks.items.len -= 1;
            if (walks.items.len == 0) return done;
            gc.push(V, vs, done);
        }
    }
}
