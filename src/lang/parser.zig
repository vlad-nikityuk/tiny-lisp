// The parser: text -> AST (numbers, symbols, string literals and lists of them).
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const V = value.V;

// Iterative, so nesting depth is limited by memory only. Symbols and literals are permanent.
var src: []const u8 = "";
var pos: usize = 0;
const space = " \t\n\r";
const unexpected = "TinyLisp: Syntax error, unexpected closing parenthesis";
const prefixes = [_][]const u8{ "quote", "quasiquote", "unquote", "unquote-splicing" }; // ' ` ~ ~@

fn peek() u8 {
    return if (pos < src.len) src[pos] else 0;
} // a 0 byte ends the source
fn skip() void {
    while (true) {
        pos = std.mem.indexOfNonePos(u8, src, pos, space) orelse src.len;
        if (peek() != ';') return;
        pos = std.mem.indexOfAnyPos(u8, src, pos, "\n\x00") orelse src.len;
    }
}
fn lex() V {
    const lit = peek() == '"';
    const start = pos + @intFromBool(lit);
    pos = std.mem.indexOfAnyPos(u8, src, start, if (lit) "\"\x00" else space ++ "\x00()'`~;\"") orelse src.len;
    const t = src[start..pos];
    if (lit and peek() == '"') pos += 1;
    if (!lit and std.mem.indexOfAny(u8, t, "0123456789") != null) if (std.fmt.parseFloat(f64, t)) |d| return V.num(d) else |_| {};
    const text = value.mkstr(t, true);
    return if (lit) V.literal(text) else V.string(text);
}

/// The whole text is one expression.
pub fn parse(text: []const u8) value.E!V {
    src = text;
    pos = 0;
    const x = try expression();
    skip();
    if (peek() != 0) return value.fail(value.str(unexpected, .{}));
    return x;
}

/// The next expression of text from position at on (which moves past it), or null when only blanks and comments remain: a file is
/// read form by form, so that the macros one form defines are known when the next one is expanded.
pub fn parseNext(text: []const u8, at: *usize) value.E!?V {
    src = text;
    pos = at.*;
    skip();
    if (peek() == 0) return null;
    const x = try expression();
    at.* = pos;
    return x;
}

fn expression() value.E!V {
    var done: std.ArrayList(V) = .empty;
    defer done.deinit(std.heap.c_allocator); // finished items, the open lists' items among them
    var open: std.ArrayList(i64) = .empty;
    defer open.deinit(std.heap.c_allocator); // where each open list starts in done; below 0: a prefix, -1 - its index in prefixes
    while (open.items.len > 0 or done.items.len == 0) {
        skip();
        var d: V = switch (peek()) {
            0 => return value.fail(value.str("TinyLisp: Syntax error, unbalanced expression", .{})),
            '(' => {
                pos += 1;
                gc.push(i64, &open, @intCast(done.items.len));
                continue;
            },
            '\'', '`', '~' => |c| {
                pos += 1;
                const k: i64 = if (c == '~' and peek() == '@') 3 else @intCast(std.mem.indexOfScalar(u8, "'`~", c).?);
                pos += @intFromBool(k == 3);
                gc.push(i64, &open, -1 - k);
                continue;
            },
            ')' => blk: {
                pos += 1;
                if (open.items.len == 0 or open.getLast() < 0) return value.fail(value.str(unexpected, .{}));
                const items = done.items[@intCast(open.pop().?)..];
                done.items.len -= items.len;
                break :blk value.list(items, items.len);
            },
            else => lex(),
        };
        while (open.items.len > 0 and open.getLast() < 0) : (_ = open.pop()) d = value.list(&.{ V.string(value.mkstr(prefixes[@intCast(-1 - open.getLast())], true)), d }, 2); // 'x is (quote x)
        gc.push(V, &done, d);
    }
    return done.items[0];
}
