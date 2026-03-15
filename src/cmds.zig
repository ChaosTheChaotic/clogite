const std = @import("std");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");

pub const Cmd = struct {
    id: i64,
    content: []const u8,
    last_run_at: i64,
    last_exit_code: i64,
    last_duration_ms: i64,
    run_count: i64,
    total_duration_ms: i64,
};

// Makes commands that are identically parsed be the same
fn normalizeCommand(alloc: std.mem.Allocator, raw_cmd: []const u8) ![]const u8 {
    var tokens = std.mem.tokenizeAny(u8, raw_cmd, " \t\n\r");
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);

    var first = true;
    while (tokens.next()) |token| {
        if (!first) try list.append(alloc, ' ');
        try list.appendSlice(alloc, token);
        first = false;
    }
    return list.toOwnedSlice(alloc);
}

pub fn addCommand(db: *sqlite.Db, raw_cmd: []const u8, exit_code: u8, duration_ms: u64) !void {
    const allocator = std.heap.smp_allocator;

    const clean_cmd = try normalizeCommand(allocator, raw_cmd);
    defer allocator.free(clean_cmd);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(clean_cmd, &hash, .{});

    const now = std.time.timestamp();

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
    try db_mod.maintenance(db);
}

pub fn removeCommand(db: *sqlite.Db, raw_cmd: []const u8) !void {
    const allocator = std.heap.smp_allocator;
    const clean_cmd = try normalizeCommand(allocator, raw_cmd);
    defer allocator.free(clean_cmd);

    try db.exec("DELETE FROM commands WHERE content = ?;", .{}, .{clean_cmd});
    try db_mod.maintenance(db);
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

pub fn getCommandInfo(allocator: std.mem.Allocator, db: *sqlite.Db, raw_cmd: []const u8) !?Cmd {
    const clean_cmd = try normalizeCommand(allocator, raw_cmd);
    defer allocator.free(clean_cmd);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(clean_cmd, &hash, .{});

    var stmt = try db.prepare(
        \\SELECT id, content, last_run_at, last_exit_code, 
        \\last_duration_ms, run_count, total_duration_ms 
        \\FROM commands WHERE content_hash = ?
    );
    defer stmt.deinit();

    return try stmt.oneAlloc(Cmd, allocator, .{}, .{
        .content_hash = &hash,
    });
}

pub fn searchCommands(alloc: std.mem.Allocator, db: *sqlite.Db, term: []const u8, case_sensitive: bool) ![]Cmd {
    if (term.len == 0) return getCommands(alloc, db, null);

    if (case_sensitive) {
        var stmt = try db.prepare(
            \\SELECT id, content, last_run_at, last_exit_code, 
            \\last_duration_ms, run_count, total_duration_ms 
            \\FROM commands WHERE INSTR(content, ?) > 0 
            \\ORDER BY last_run_at DESC
        );
        defer stmt.deinit();
        return try stmt.all(Cmd, alloc, .{}, .{term});
    } else {
        var stmt = try db.prepare(
            \\SELECT id, content, last_run_at, last_exit_code, 
            \\last_duration_ms, run_count, total_duration_ms 
            \\FROM commands WHERE content LIKE ? 
            \\ORDER BY last_run_at DESC
        );
        defer stmt.deinit();
        const like_term = try std.fmt.allocPrint(alloc, "%{s}%", .{term});
        defer alloc.free(like_term);
        return try stmt.all(Cmd, alloc, .{}, .{like_term});
    }
}
