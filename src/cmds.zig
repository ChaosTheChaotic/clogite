const std = @import("std");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");
const ctx = @import("ctx.zig");

pub const Cmd = struct {
    id: i64,
    content: []const u8,
    last_run_at: i64,
    last_exit_code: i64,
    last_duration_ms: i64,
    run_count: i64,
    total_duration_ms: i64,
};

pub const ExitCodeStat = struct {
    exit_code: u8,
    frequency: u64,
};

pub const CmdDetail = struct {
    cmd: Cmd,
    exit_codes: []ExitCodeStat,

    pub fn deinit(self: CmdDetail, alloc: std.mem.Allocator) void {
        alloc.free(self.exit_codes);
    }
};

pub const SegStat = struct {
    cmd_smry: Cmd,
    exit_codes: []ExitCodeStat,
    match_count: usize,

    pub fn deinit(self: SegStat, alloc: std.mem.Allocator) void {
        alloc.free(self.exit_codes);
    }
};

pub const TokenRange = struct {
    start: usize,
    end: usize,
};

pub const ShellTokenIterator = struct {
    content: []const u8,
    index: usize = 0,

    pub fn init(content: []const u8) ShellTokenIterator {
        return .{ .content = content };
    }

    pub fn next(self: *ShellTokenIterator) ?TokenRange {
        const len = self.content.len;
        while (self.index < len and std.ascii.isWhitespace(self.content[self.index])) {
            self.index += 1;
        }
        if (self.index >= len) return null;

        const start = self.index;
        var in_single_quote = false;
        var in_double_quote = false;
        var paren_depth: i32 = 0;
        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var escaped = false;

        const c_start = self.content[self.index];
        if (!escaped and !in_single_quote and !in_double_quote and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
            if (c_start == '|' or c_start == '&' or c_start == ';') {
                self.index += 1;
                if (self.index < len and self.content[self.index] == c_start) {
                    self.index += 1;
                }
                return TokenRange{ .start = start, .end = self.index };
            }
        }

        while (self.index < len) {
            const c = self.content[self.index];

            if (escaped) {
                escaped = false;
                self.index += 1;
                continue;
            }

            if (c == '\\') {
                escaped = true;
                self.index += 1;
                continue;
            }

            if (in_single_quote) {
                if (c == '\'') {
                    in_single_quote = false;
                }
                self.index += 1;
                continue;
            }

            if (in_double_quote) {
                if (c == '"') {
                    in_double_quote = false;
                }
                self.index += 1;
                continue;
            }

            // Outside quotes
            if (c == '\'') {
                in_single_quote = true;
                self.index += 1;
            } else if (c == '"') {
                in_double_quote = true;
                self.index += 1;
            } else if (c == '(') {
                paren_depth += 1;
                self.index += 1;
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
                self.index += 1;
            } else if (c == '{') {
                brace_depth += 1;
                self.index += 1;
            } else if (c == '}') {
                if (brace_depth > 0) brace_depth -= 1;
                self.index += 1;
            } else if (c == '[') {
                bracket_depth += 1;
                self.index += 1;
            } else if (c == ']') {
                if (bracket_depth > 0) bracket_depth -= 1;
                self.index += 1;
            } else if (std.ascii.isWhitespace(c) and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                break;
            } else if ((c == '|' or c == '&' or c == ';') and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                if (self.index == start) {
                    self.index += 1;
                    if (self.index < len and self.content[self.index] == c) {
                        self.index += 1;
                    }
                }
                break;
            } else {
                self.index += 1;
            }
        }

        if (self.index == start) return null;
        return TokenRange{ .start = start, .end = self.index };
    }
};

// Makes commands that are identically parsed be the same
fn normalizeCommand(alloc: std.mem.Allocator, raw_cmd: []const u8) ![]const u8 {
    var it = ShellTokenIterator.init(raw_cmd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    var first = true;
    while (it.next()) |tr| {
        if (!first) try list.append(alloc, ' ');
        try list.appendSlice(alloc, raw_cmd[tr.start..tr.end]);
        first = false;
    }
    return list.toOwnedSlice(alloc);
}

pub fn addCommand(ctxi: *ctx.Ctx, raw_cmd: []const u8, exit_code: u8, duration_ms: u64) !void {
    const alloc = ctxi.alloc;
    var db = ctxi.db orelse return error.DatabaseNotInitialized;

    const clean_cmd = try normalizeCommand(alloc, raw_cmd);
    defer alloc.free(clean_cmd);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(clean_cmd, &hash, .{});

    const now = std.Io.Clock.real.now(ctxi.io).toSeconds();

    try db.exec(
        \\INSERT INTO commands (
        \\    content, content_hash, last_run_at, last_exit_code, 
        \\    last_duration_ms, run_count, total_duration_ms
        \\) VALUES (?, ?, ?, ?, ?, 1, ?)
        \\ON CONFLICT(content_hash) DO UPDATE SET
        \\    last_run_at = excluded.last_run_at,
        \\    last_exit_code = excluded.last_exit_code,
        \\    last_duration_ms = excluded.last_duration_ms,
        \\    run_count = commands.run_count + 1,
        \\    total_duration_ms = commands.total_duration_ms + excluded.last_duration_ms;
    , .{}, .{
        .content = clean_cmd,
        .content_hash = &hash,
        .last_run_at = now,
        .last_exit_code = exit_code,
        .last_duration_ms = duration_ms,
        .total_duration_ms = duration_ms,
    });

    try db.exec(
        \\INSERT INTO exit_code_stats (command_id, exit_code, frequency)
        \\SELECT id, ?, 1 FROM commands WHERE content_hash = ?
        \\ON CONFLICT(command_id, exit_code) DO UPDATE SET
        \\    frequency = exit_code_stats.frequency + 1;
    , .{}, .{ exit_code, &hash });
    try db_mod.maintenance(&db);
}

pub fn removeCommand(ctxi: *ctx.Ctx, raw_cmd: []const u8) !void {
    const alloc = ctxi.alloc;
    var db = ctxi.db orelse return error.DatabaseNotInitialized;
    const clean_cmd = try normalizeCommand(alloc, raw_cmd);
    defer alloc.free(clean_cmd);

    try db.exec("DELETE FROM commands WHERE content = ?;", .{}, .{clean_cmd});
    try db_mod.maintenance(&db);
}

pub fn getCommands(alloc: std.mem.Allocator, db: *sqlite.Db, limit: ?usize) ![]Cmd {
    var stmt = try db.prepare(
        \\SELECT id, content, last_run_at, last_exit_code, 
        \\last_duration_ms, run_count, total_duration_ms 
        \\FROM commands ORDER BY last_run_at DESC LIMIT ?
    );
    defer stmt.deinit();

    const limit_val: i64 = if (limit) |l| @as(i64, @intCast(l)) else -1;

    return try stmt.all(Cmd, alloc, .{}, .{limit_val});
}

pub fn getCommandInfo(alloc: std.mem.Allocator, ctxi: *ctx.Ctx, raw_cmd: []const u8) !?CmdDetail {
    var db = ctxi.db orelse return error.DatabaseNotInitialized;
    const clean_cmd = try normalizeCommand(alloc, raw_cmd);
    defer alloc.free(clean_cmd);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(clean_cmd, &hash, .{});

    var cmd_stmt = try db.prepare(
        \\SELECT id, content, last_run_at, last_exit_code, 
        \\last_duration_ms, run_count, total_duration_ms 
        \\FROM commands WHERE content_hash = ?
    );
    defer cmd_stmt.deinit();

    const cmd = (try cmd_stmt.oneAlloc(Cmd, alloc, .{}, .{
        .content_hash = &hash,
    })) orelse return null;

    var stats_stmt = try db.prepare(
        \\SELECT exit_code, frequency 
        \\FROM exit_code_stats 
        \\WHERE command_id = ? 
        \\ORDER BY frequency DESC
    );
    defer stats_stmt.deinit();

    const exit_codes = try stats_stmt.all(ExitCodeStat, alloc, .{}, .{cmd.id});

    return CmdDetail{
        .cmd = cmd,
        .exit_codes = exit_codes,
    };
}

pub fn searchCommands(ctxi: *ctx.Ctx, alloc: std.mem.Allocator, term: []const u8, case_sensitive: bool, regex: bool) ![]Cmd {
    const io = ctxi.io;
    var db = ctxi.db orelse return error.DatabaseNotInitialized;
    if (term.len == 0) return getCommands(alloc, &db, null);

    if (!regex) {
        if (term.len == 0) return getCommands(alloc, &db, null);

        if (case_sensitive) {
            var stmt = try db.prepare(
                \\SELECT id, content, last_run_at, last_exit_code,
                \\       last_duration_ms, run_count, total_duration_ms
                \\FROM commands WHERE content LIKE ?
                \\ORDER BY last_run_at DESC
            );
            defer stmt.deinit();
            const like_term = try alloc.print("%{s}%", .{term});
            defer alloc.free(like_term);
            return try stmt.all(Cmd, alloc, .{}, .{like_term});
        } else {
            var stmt = try db.prepare(
                \\SELECT id, content, last_run_at, last_exit_code,
                \\       last_duration_ms, run_count, total_duration_ms
                \\FROM commands WHERE INSTR(content, ?) > 0
                \\ORDER BY last_run_at DESC
            );
            defer stmt.deinit();
            return try stmt.all(Cmd, alloc, .{}, .{term});
        }
    }

    const pattern = if (case_sensitive)
        try alloc.print("(?i){s}", .{term})
    else
        try alloc.dupe(u8, term);
    defer alloc.free(pattern);

    // Validate the regex without printing errors to stderr.
    {
        const original_stderr = std.os.linux.STDERR_FILENO;
        const saved_fd = std.os.linux.dup(original_stderr);
        defer _ = std.os.linux.close(@intCast(saved_fd));

        const null_fd = try std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write });
        defer null_fd.close(io);

        _ = std.os.linux.dup2(null_fd.handle, original_stderr);
        defer {
            _ = std.os.linux.dup2(@intCast(saved_fd), original_stderr);
        }

        var validate_stmt = try db.prepare("SELECT regex(?)");
        defer validate_stmt.deinit();

        if (validate_stmt.all([]u8, alloc, .{}, .{pattern})) |_| {} else |_| {
            return &[_]Cmd{};
        }
    }

    var stmt = try db.prepare(
        \\SELECT id, content, last_run_at, last_exit_code,
        \\       last_duration_ms, run_count, total_duration_ms
        \\FROM commands WHERE content REGEXP ?
        \\ORDER BY last_run_at DESC
    );
    defer stmt.deinit();

    return stmt.all(Cmd, alloc, .{}, .{pattern}) catch {
        return &[_]Cmd{};
    };
}

pub fn getSuggestion(ctxi: *ctx.Ctx, pfx: []const u8) !?[]const u8 {
    var db = ctxi.db orelse return error.DatabaseNotInitialized;

    var stmt = try db.prepare(
        \\SELECT content FROM commands
        \\WHERE content LIKE ?
        \\ORDER BY last_run_at DESC LIMIT 1
    );
    defer stmt.deinit();

    const like_pfx = try ctxi.alloc.print("{s}%", .{pfx});
    defer ctxi.alloc.free(like_pfx);

    if (try stmt.oneAlloc(struct { content: []const u8 }, ctxi.alloc, .{}, .{like_pfx})) |row| {
        return row.content;
    }
    return null;
}

pub fn tokenizeCmd(alloc: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var tkns: std.ArrayList([]const u8) = .empty;

    var it = ShellTokenIterator.init(content);
    while (it.next()) |tr| {
        try tkns.append(alloc, content[tr.start..tr.end]);
    }

    return tkns.toOwnedSlice(alloc);
}

pub fn getSegCmdInfo(alloc: std.mem.Allocator, ctxi: *ctx.Ctx, seg: []const u8) !?SegStat {
    var db = ctxi.db orelse return error.DatabaseNotInitialized;

    const ptrn = try alloc.print("%{s}%", .{seg});
    defer alloc.free(ptrn);

    var stmt = try db.prepare(
        \\SELECT
        \\  SUM(run_count),
        \\  SUM(total_duration_ms),
        \\  MAX(last_run_at),
        \\  COUNT(*)
        \\FROM commands
        \\WHERE content LIKE ? OR content = ?
    );
    defer stmt.deinit();

    const row = (try stmt.oneAlloc(struct {
        sum_runs: ?i64,
        sum_duration_ms: ?i64,
        max_last_run: ?i64,
        match_count: ?i64,
    }, alloc, .{}, .{ ptrn, seg })) orelse return null;
    const run_count = row.sum_runs orelse 0;
    if (run_count == 0) return null;

    const total_dur = row.sum_duration_ms orelse 0;
    const match_count = @as(usize, @intCast(row.match_count orelse 0));

    var exit_stmt = try db.prepare(
        \\SELECT e.exit_code, SUM(e.frequency) as total_freq
        \\FROM exit_code_stats e
        \\JOIN commands c ON e.command_id = c.id
        \\WHERE c.content LIKE ? OR c.content = ?
        \\GROUP BY e.exit_code
        \\ORDER BY total_freq DESC
    );
    defer exit_stmt.deinit();

    const exit_codes = try exit_stmt.all(ExitCodeStat, alloc, .{}, .{ ptrn, seg });

    const smry_cmd = Cmd{
        .id = 0,
        .content = seg,
        .last_run_at = row.max_last_run orelse 0,
        .last_exit_code = 0,
        .last_duration_ms = if (run_count > 0) @divTrunc(total_dur, run_count) else 0,
        .run_count = run_count,
        .total_duration_ms = total_dur,
    };

    return SegStat{
        .cmd_smry = smry_cmd,
        .exit_codes = exit_codes,
        .match_count = match_count,
    };
}
