const std = @import("std");
const builtin = @import("builtin");
pub const db = @import("db.zig");
pub const tui = @import("tui.zig");
pub const cmds = @import("cmds.zig");
pub const program_info = @import("program_info");

pub fn print(io: std.Io, comptime txt: []const u8, args: anytype) !void {
    var stdout = std.Io.File.stdout().writer(io, &.{});

    try stdout.interface.print(txt ++ "\n", args);
    try stdout.interface.flush();
}

pub fn getAppDataDir(alloc: std.mem.Allocator, env: std.process.Environ.Map, comptime name: []const u8) ![]u8 {
    const root_path = switch (builtin.os.tag) {
        .windows => win_blk: {
            const local_app = env.get("LOCALAPPDATA") orelse return error.EnvironmentVariableNotFound;
            break :win_blk try alloc.dupe(u8, local_app);
        },
        .macos => macos_blk: {
            const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
            break :macos_blk try std.fs.path.join(alloc, &.{ home, "Library", "Application Support" });
        },
        else => xdg_blk: {
            if (env.get("XDG_DATA_HOME")) |val| {
                break :xdg_blk try alloc.dupe(u8, val);
            } else {
                const home = env.get("HOME") orelse return error.EnvironmentVariableNotFound;
                break :xdg_blk try std.fs.path.join(alloc, &.{ home, ".local", "share" });
            }
        },
    };
    const final = try std.fs.path.join(alloc, &.{ root_path, name });
    alloc.free(root_path);

    return final;
}
