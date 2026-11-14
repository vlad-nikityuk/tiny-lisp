// CLI and REPL: loads the stdlib, then runs a file (-f) or reads expressions from stdin.
const std = @import("std");
const value = @import("runtime/value.zig");
const scope = @import("runtime/scope.zig");
const machine = @import("runtime/machine.zig");
const continuation = @import("runtime/continuation.zig");
const primitives = @import("runtime/primitives.zig");
const parser = @import("lang/parser.zig");
const expand = @import("lang/expand.zig");
const source = @import("lib/source.zig");
const natives = @import("lib/natives.zig");
const gpa = std.heap.c_allocator;

fn die() noreturn {
    natives.out.flush() catch {};
    std.debug.print("\x1b[31m{f}\x1b[39m\n", .{value.errv});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var obuf: [4096]u8 = undefined;
    var ow: std.Io.File.Writer = .init(.stdout(), init.io, &obuf);
    const out = &ow.interface;
    natives.out = out;
    defer out.flush() catch {};
    const e = scope.init();
    primitives.install(e);
    machine.install(e);
    continuation.install(e);
    var file: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--debug")) {
            scope.set(e, "*DEBUG*", value.V.boolean(true));
            try out.writeAll("\x1b[33mDebug mode enabled\x1b[39m\n");
        }
        if (std.mem.eql(u8, a, "-f") and i + 1 < args.len) file = args[i + 1];
    }
    natives.io = init.io;
    natives.install(e);
    _ = source.runFile(init.io, "src/lib/stdlib.lisp", e) catch die();
    if (file) |f| return if (source.runFile(init.io, f, e)) |_| {} else |_| die();
    const ibuf = try gpa.alloc(u8, 1 << 24);
    var in: std.Io.File.Reader = .init(.stdin(), init.io, ibuf);
    while (true) {
        try out.writeAll("#> ");
        try out.flush();
        const line = try in.interface.takeDelimiter('\n') orelse return;
        const s = std.mem.trimStart(u8, line, " \t\r\n");
        if (s.len == 0) continue;
        if (parser.parse(s)) |x| if (expand.run(x, e)) |v| {
            try out.print("\x1b[32m{f}\x1b[39m\n", .{v});
            continue;
        } else |_| {} else |_| {}
        try out.print("\x1b[31m{f}\x1b[39m\n", .{value.errv});
    }
}
