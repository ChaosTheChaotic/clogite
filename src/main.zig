const std = @import("std");
const clogite = @import("clogite");

const SubCmd = enum {
    help,
    version,
    add,
    remove,
    view,
    init,
    suggest,

    pub fn parse(str: []const u8) ?SubCmd {
        if (std.mem.eql(u8, str, "rem")) {
            return .remove;
        }
        return std.meta.stringToEnum(SubCmd, str);
    }
};

fn print_help(io: std.Io) !void {
    try clogite.print(io,
        \\clogite - A command history and statistics logger
        \\
        \\Usage:
        \\  clogite add "<command>" <exit_code> <duration_ms>
        \\  clogite rem "<command>"
        \\  clogite init <keep_histfile> <modify_zsh_autosuggestions>
        \\  clogite view
        \\  clogite version
        \\  clogite help
        \\  clogite suggest "<pfx>"
        \\
        \\Options:
        \\  add          Log a new command execution.
        \\  rem/remove   Remove a command from the history.
        \\  init         Adds the needed commands for zsh to integrate the program properly.
        \\  view         Open the TUI to search and view history.
        \\  version      Show program version.
        \\  suggest      Suggests a command to run based on a prefix
        \\
        \\TUI Keybinds:
        \\  ↑ / ↓        Navigate command history 
        \\  Enter        Select and run the highlighted command 
        \\  Tab          Insert command into your terminal prompt 
        \\  Ctrl + O     View detailed statistics for the selected command 
        \\  Ctrl + D     Remove the selected command from history 
        \\  Esc / Ctrl+C Back to history or exit the TUI 
        \\  Typing       Filters the command history (search) 
    , .{});
}

inline fn errSub(sub: []const u8) noreturn {
    std.log.err("clogite {s} requires a command, an exit code and a duration (in ms)", .{sub});
    std.process.exit(22);
}

fn parseBool(str: []const u8) bool {
    if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "1") or std.mem.eql(u8, str, "yes")) {
        return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // Skip the program path

    const subcmd_str = args.next() orelse {
        // No args were passed
        try print_help(init.io);
        return;
    };

    var ctx = try clogite.ctx.Ctx.init(&init, std.heap.smp_allocator);
    defer ctx.deinit();

    // Parse the captured subcommand directly
    switch (SubCmd.parse(subcmd_str) orelse {
        std.log.warn("Ignoring unknown argument: {s}\n", .{subcmd_str});
        try print_help(init.io);
        return;
    }) {
        .help => {
            try print_help(init.io);
            std.process.exit(0);
        },
        .version => {
            try clogite.print(init.io, "Version: {f}", .{clogite.program_info.program_version});
        },
        .add => {
            ctx.db = try clogite.db.initDb(ctx);
            const cmd = args.next() orelse errSub("add");
            const exit_str = args.next() orelse errSub("add");
            const exit = try std.fmt.parseInt(u8, exit_str, 10);
            const dur_str = args.next() orelse errSub("add");
            const dur = try std.fmt.parseInt(u64, dur_str, 10);
            try clogite.cmds.addCommand(&ctx, cmd, exit, dur);
            return;
        },
        .remove => {
            ctx.db = try clogite.db.initDb(ctx);
            const cmd = args.next() orelse errSub("remove");
            try clogite.cmds.removeCommand(&ctx, cmd);
            return;
        },
        .view => {
            const alloc = ctx.alloc;
            ctx.db = try clogite.db.initDb(ctx);
            if (try clogite.tui.initTui(&ctx)) |selected_cmd| {
                defer alloc.free(selected_cmd);
                const shell_env = init.environ_map.get("SHELL") orelse null;

                if (shell_env) |shell_path| {
                    defer alloc.free(shell_path);

                    if (std.mem.endsWith(u8, shell_path, "zsh")) {
                        var stdout = std.Io.File.stdout().writer(init.io, &.{});

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
            var stdout = std.Io.File.stdout().writer(init.io, &.{});

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
                \\        duration_ms=${duration_ms%.*}
                \\        clogite add "$__clogite_cmd" $exit_code $duration_ms &|
                \\    fi
                \\    __clogite_start=
                \\    __clogite_cmd=
                \\}
                \\
                \\__clogite_history_widget() {
                \\    local selected="$(clogite view)"
                \\    if [[ -n "$selected" ]]; then
                \\        local mode="${selected[1]}"
                \\        local cmd="${selected[2,-1]}"
                \\        case "$mode" in
                \\            $'\x1E')
                \\                BUFFER="$cmd"
                \\                CURSOR=$#BUFFER
                \\                zle accept-line
                \\                ;;
                \\            $'\x1F')
                \\                BUFFER="$cmd"
                \\                CURSOR=$#BUFFER
                \\                ;;
                \\            *)         # Fallback (shouldnt happen)
                \\                BUFFER="$selected"
                \\                CURSOR=$#BUFFER
                \\                ;;
                \\        esac
                \\    fi
                \\    zle reset-prompt
                \\}
                \\
                \\autoload -Uz add-zsh-hook
                \\add-zsh-hook preexec __clogite_preexec
                \\add-zsh-hook precmd __clogite_precmd
                \\
                \\zle -N __clogite_history_widget
                \\bindkey '\e[A' __clogite_history_widget
                \\bindkey '\eOA' __clogite_history_widget
                \\
            ;
            try stdout.interface.writeAll(zsh_init_script);

            if (!parseBool(args.next() orelse "false")) {
                const zsh_disable_histfile =
                    \\unset HISTFILE
                    \\SAVEHIST=0
                    \\HISTSIZE=1000
                    \\
                ;
                try stdout.interface.writeAll(zsh_disable_histfile);
            }
            if (parseBool(args.next() orelse "false")) {
                const zsh_mod_autosuggestions =
                    \\_zsh_autosuggest_strategy_clogite() {
                    \\    local query="$1"
                    \\    suggestion=$(clogite suggest "$query" 2>/dev/null)
                    \\}
                    \\
                    \\export ZSH_AUTOSUGGEST_STRATEGY=(clogite completion)
                    \\
                ;
                try stdout.interface.writeAll(zsh_mod_autosuggestions);
            }
            try stdout.interface.flush();
            return;
        },
        .suggest => {
            ctx.db = try clogite.db.initDb(ctx);
            const pfx = args.next() orelse {
                std.log.err("The suggest command requires passing in a pattern", .{});
                std.process.exit(22);
            };
            if (try clogite.cmds.getSuggestion(&ctx, pfx)) |suggestion| {
                var stdout = std.Io.File.stdout().writer(init.io, &.{});
                try stdout.interface.writeAll(suggestion);
                try stdout.interface.flush();
            }
        },
    }
}
