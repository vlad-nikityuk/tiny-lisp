// Program files: the text of a file, and running a file form by form (for the REPL's -f and the stdlib).
const std = @import("std");
const value = @import("../runtime/value.zig");
const scope = @import("../runtime/scope.zig");
const parser = @import("../lang/parser.zig");
const expand = @import("../lang/expand.zig");

/// The whole text of the file at path, to be freed by the caller.
pub fn readText(io: std.Io, path: []const u8) value.E![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, value.gpa, .unlimited) catch
        value.fail(value.str("cannot open {s}", .{path}));
}

/// Read, expand and run the forms of a file one after the other, in e: a macro that one form defines is in effect for the next
/// one, and what the earlier forms defined is there when a later one is expanded. The value is the last form's.
pub fn runFile(io: std.Io, path: []const u8, e: *scope.Env) value.E!value.V {
    const text = try readText(io, path);
    defer value.gpa.free(text);
    var at: usize = 0;
    var last = value.V.nil;
    while (try parser.parseNext(text, &at)) |x| last = try expand.run(x, e);
    return last;
}
