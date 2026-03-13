const std = @import("std");
pub const db = @import("db.zig");

pub fn print(comptime txt: []const u8, args: anytype) !void {
    var stdout = std.fs.File.stdout().writer(&.{});

    try stdout.interface.print(txt ++ "\n", args);
    try stdout.interface.flush();
}
