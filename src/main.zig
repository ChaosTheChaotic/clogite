const std = @import("std");
const clogite = @import("clogite");

const SubCmd = enum {
    help,
    version,
    add,
    remove,
    view,

    pub fn parse(str: []const u8) ?SubCmd {
        if (std.mem.eql(u8, str, "rem")) {
            return .remove;
        }
        return std.meta.stringToEnum(SubCmd, str);
    }
};

fn print_help() !void {
    try clogite.print(
        \\clogite - A command history and statistics logger
        \\
        \\Usage:
        \\  clogite add "<command>" <exit_code> <duration_ms>
        \\  clogite rem "<command>"
        \\  clogite view
        \\  clogite version
        \\  clogite help
        \\
        \\Options:
        \\  add      Log a new command execution.
        \\  rem/remove  Remove a command from the history.
        \\  view     Open the TUI to search and view history.
        \\  version  Show program version.
    , .{});
}

fn errSub(sub: []const u8) noreturn {
    std.log.err("clogite {s} requires a command, an exit code and a duration (in ms)", .{sub});
    std.process.exit(22);
}

pub fn main() !void {
    var db: ?clogite.db.sqlite.Db = null;
    defer if (db) |*d| d.deinit();
    var args = std.process.args();
    _ = args.next(); // Skip the program path
    while (args.next()) |arg| {
        switch (SubCmd.parse(arg) orelse {
            std.log.warn("Ignoring unknown argument: {s}\n", .{arg});
            continue;
        }) {
            .help => {
                try print_help();
                std.process.exit(0);
            },
            .version => {
                try clogite.print("Version: {f}", .{clogite.program_info.program_version});
            },
            .add => {
                db = try clogite.db.initDb();
                const cmd = args.next() orelse errSub("add");
                const exit_str = args.next() orelse errSub("add");
                const exit = try std.fmt.parseInt(u8, exit_str, 10);
                const dur_str = args.next() orelse errSub("add");
                const dur = try std.fmt.parseInt(u64, dur_str, 10);
                try clogite.cmds.addCommand(&db.?, cmd, exit, dur);
                return;
            },
            .remove => {
                db = try clogite.db.initDb();
                const cmd = args.next() orelse errSub("remove");
                try clogite.cmds.removeCommand(&db.?, cmd);
                return;
            },
            .view => {
                db = try clogite.db.initDb();
                try clogite.tui.initTui(&db.?);
                return;
            },
        }
    }
}
