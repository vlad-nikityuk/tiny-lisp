// Whole-file programs are a begin form; the newline keeps trailing comments from hiding its closing parenthesis.
const std = @import("std");
const value = @import("../runtime/value.zig");
const gc = @import("../runtime/gc.zig");
const parser = @import("../lang/parser.zig");
pub fn readProgram(io: std.Io, path: []const u8) value.E!value.V {
    const gpa = std.heap.c_allocator;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch
        return value.fail(value.str("cannot open {s}", .{path}));
    defer gpa.free(text);
    const program = std.fmt.allocPrint(gpa, "(begin {s}\n)", .{text}) catch gc.oom();
    defer gpa.free(program);
    return parser.parse(program);
}
