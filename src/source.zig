// Whole-file programs are a begin form; the newline keeps trailing comments from hiding its closing parenthesis.
const std = @import("std");
const gc = @import("runtime/gc.zig");
const rt = @import("runtime/runtime.zig");
const parser = @import("parser.zig");

pub fn readProgram(io: std.Io, path: []const u8) rt.E!rt.V {
    const gpa = std.heap.c_allocator;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch
        return rt.fail(rt.str("cannot open {s}", .{path}));
    defer gpa.free(text);
    const program = std.fmt.allocPrint(gpa, "(begin {s}\n)", .{text}) catch gc.oom();
    defer gpa.free(program);
    return parser.parse(program);
}
