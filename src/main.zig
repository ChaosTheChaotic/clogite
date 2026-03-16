const std = @import("std");
const clogite = @import("clogite");

const SubCmd = enum {
    help,
    version,
    add,
    remove,
    view,
    init,

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
        \\  clogite init
        \\  clogite view
        \\  clogite version
        \\  clogite help
        \\
        \\Options:
        \\  add      Log a new command execution.
        \\  rem/remove  Remove a command from the history.
        \\  init Adds the needed commands for zsh to integrate the program properly
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
    if (std.os.argv.len <= 1) {
        try print_help();
        return;
    }
    while (args.next()) |arg| {
        switch (SubCmd.parse(arg) orelse {
            std.log.warn("Ignoring unknown argument: {s}\n", .{arg});
            try print_help();
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
                const alloc = std.heap.smp_allocator;
                db = try clogite.db.initDb();
                if (try clogite.tui.initTui(&db.?)) |selected_cmd| {
                    defer alloc.free(selected_cmd);
                    const shell_env = std.process.getEnvVarOwned(alloc, "SHELL") catch |err|
                        if (err == error.EnvironmentVariableNotFound) null else return err;

                    if (shell_env) |shell_path| {
                        defer alloc.free(shell_path);

                        if (std.mem.endsWith(u8, shell_path, "zsh")) {
                            var stdout = std.fs.File.stdout().writer(&.{});

                            try stdout.interface.writeAll(selected_cmd);
                            try stdout.interface.flush();
                        } else if (std.mem.endsWith(u8, shell_path, "bash")) {
                            // I dont know what to do for this one
                        } else {
                            // I dont know or think about other shells very often
                        }
                    }
                }
                return;
            },
            .init => {
                const zsh_init_script =
                    \\zmodload zsh/datetime
                    \\
                    \\__clogite_preexec() {
                    \\    __clogite_cmd=$1
                    \\    __clogite_start=$EPOCHREALTIME
                    \\}
                    \\
                    \\__clogite_precmd() {
                    \\    local exit_code=$?
                    \\    if [[ -n "$__clogite_start" && -n "$__clogite_cmd" ]]; then
                    \\        local duration_ms=$(( (EPOCHREALTIME - __clogite_start) * 1000 ))
                    \\        # Truncate fractional milliseconds
                    \\        duration_ms=${duration_ms%.*}
                    \\        
                    \\        # Run asynchronously so prompt isn't delayed
                    \\        clogite add "$__clogite_cmd" $exit_code $duration_ms &|
                    \\    fi
                    \\    __clogite_start=
                    \\    __clogite_cmd=
                    \\}
                    \\
                    \\autoload -Uz add-zsh-hook
                    \\add-zsh-hook preexec __clogite_preexec
                    \\add-zsh-hook precmd __clogite_precmd
                    \\
                    \\# Bind Up Arrow to clear the line (^U) and run the view UI
                    \\bindkey -s '^[[A' '^Ueval $(clogite view)\n'
                    \\bindkey -s '^[OA' '^Ueval $(clogite view)\n'
                ;
                var stdout = std.fs.File.stdout().writer(&.{});

                try stdout.interface.writeAll(zsh_init_script);
                try stdout.interface.flush();
                return;
            },
        }
    }
}
