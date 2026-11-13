// CLI and REPL: loads the stdlib, then runs a file (-f) or reads expressions from stdin.
const std = @import("std");
const source = @import("source.zig");
const lang = @import("lang.zig");
const rt = @import("runtime.zig");
const native = @import("stdlib_native.zig");

const gpa = std.heap.c_allocator;

fn load(io: std.Io, e: *rt.Env, path: []const u8) rt.E!void {
    _ = try lang.eval(try source.readProgram(io, path), e);
}

fn die() noreturn {
    lang.out.flush() catch {};
    std.debug.print("\x1b[31m{f}\x1b[39m\n", .{lang.errv});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var obuf: [4096]u8 = undefined;
    var ow: std.Io.File.Writer = .init(.stdout(), init.io, &obuf);
    const out = &ow.interface;
    lang.out = out;
    defer out.flush() catch {};
    const e = rt.topLevel();
    var file: ?[]const u8 = null;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--debug")) {
            rt.set(e, "*DEBUG*", rt.V.boolean(true));
            try out.writeAll("\x1b[33mDebug mode enabled\x1b[39m\n");
        }
        if (std.mem.eql(u8, a, "-f") and i + 1 < args.len) file = args[i + 1];
    }
    native.io = init.io;
    native.install(e);
    load(init.io, e, "src/stdlib.lisp") catch die();
    if (file) |f| return load(init.io, e, f) catch die();
    const ibuf = try gpa.alloc(u8, 1 << 24);
    var in: std.Io.File.Reader = .init(.stdin(), init.io, ibuf);
    while (true) {
        try out.writeAll("#> ");
        try out.flush();
        const line = try in.interface.takeDelimiter('\n') orelse return;
        const s = std.mem.trimStart(u8, line, " \t\r\n");
        if (s.len == 0) continue;
        if (lang.parse(s)) |x| if (lang.eval(x, e)) |v| {
            try out.print("\x1b[32m{f}\x1b[39m\n", .{v});
            continue;
        } else |_| {} else |_| {}
        try out.print("\x1b[31m{f}\x1b[39m\n", .{lang.errv});
    }
}
