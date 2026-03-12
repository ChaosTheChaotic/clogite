const std = @import("std");
const clogite = @import("clogite");

pub fn main() !void {
    try clogite.print("Hello, world!", .{});
}
