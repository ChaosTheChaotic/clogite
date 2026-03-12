const std = @import("std");
const sqlite = @import("sqlite");
const program_info = @import("program_info");

pub fn print(comptime txt: []const u8, args: anytype) !void {
    var stdout = std.fs.File.stdout().writer(&.{});

    try stdout.interface.print(txt ++ "\n", args);
    try stdout.interface.flush();
}

pub inline fn getDbPath(alloc: std.mem.Allocator) [:0]const u8 {
    const data_dir = std.fs.getAppDataDir(alloc, program_info.program_name) catch |e| blk: {
        std.log.err("Error getting app data path: {}", .{e});
        std.log.warn("Falling back to cwd", .{});
        break :blk std.fs.cwd().realpathAlloc(alloc, ".") catch |fe| {
            std.log.err("Fatal: {}", .{fe});
            std.process.exit(1);
        };
    };
    defer alloc.free(data_dir);

    const path = std.fs.path.joinZ(alloc, &.{ data_dir, "clog.db" }) catch |e| {
        std.log.err("Failed to join path {s}: {}", .{ data_dir, e });
        std.process.exit(1);
    };
    return path;
}

// TODO: Validate the contents of the database
pub inline fn checkDbExists(db_path: ?[:0]const u8) bool {
    const alloc = std.heap.smp_allocator;

    const path = db_path orelse getDbPath(alloc);
    defer if (db_path == null) alloc.free(path);
    std.fs.accessAbsolute(path, .{}) catch {
        return false;
    };
    return true;
}

fn createCommandsTable(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS commands (
        \\    id INTEGER PRIMARY KEY,
        \\    content TEXT UNIQUE NOT NULL,
        \\    last_run_at INTEGER NOT NULL,
        \\    last_exit_code INTEGER NOT NULL,
        \\    last_duration_ms INTEGER NOT NULL,
        \\    run_count INTEGER DEFAULT 1,
        \\    total_duration_ms INTEGER NOT NULL
        \\);
    , .{}, .{});
}

fn createExitCodeStatsTable(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS exit_code_stats (
        \\    command_id INTEGER NOT NULL,
        \\    exit_code INTEGER NOT NULL,
        \\    frequency INTEGER DEFAULT 1,
        \\    PRIMARY KEY (command_id, exit_code),
        \\    FOREIGN KEY (command_id) REFERENCES commands(id) ON DELETE CASCADE
        \\);
    , .{}, .{});
}

fn createFtsTable(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE VIRTUAL TABLE IF NOT EXISTS commands_fts USING fts5(
        \\    content,
        \\    content='commands',
        \\    content_rowid='id'
        \\);
    , .{}, .{});
}

fn createIndexes(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE INDEX IF NOT EXISTS idx_commands_last_run ON commands(last_run_at);
        \\CREATE INDEX IF NOT EXISTS idx_commands_exit_code ON commands(last_exit_code);
        \\CREATE INDEX IF NOT EXISTS idx_commands_run_count ON commands(run_count);
    , .{}, .{});
}

fn createTriggers(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE TRIGGER IF NOT EXISTS commands_ai AFTER INSERT ON commands BEGIN
        \\  INSERT INTO commands_fts(rowid, content) VALUES (new.id, new.content);
        \\END;
        \\
        \\CREATE TRIGGER IF NOT EXISTS commands_au AFTER UPDATE ON commands BEGIN
        \\  INSERT INTO commands_fts(commands_fts, rowid, content) VALUES('delete', old.id, old.content);
        \\  INSERT INTO commands_fts(rowid, content) VALUES (new.id, new.content);
        \\END;
    , .{}, .{});
}

pub fn initDb() !void {
    const alloc = std.heap.smp_allocator;
    const db_path = getDbPath(alloc);
    if (checkDbExists(db_path)) {
        return;
    }

    if (std.fs.path.dirname(db_path)) |dir| {
        std.fs.cwd().makePath(dir) catch |e| {
            std.log.err("Failed to create directory {s}: {}", .{ dir, e });
            return e;
        };
    }

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = db_path },
        .open_flags = .{ .create = true, .write = true },
        .threading_mode = .MultiThread,
    });

    try db.exec("BEGIN TRANSACTION;", .{}, .{});

    try createCommandsTable(&db);
    try createExitCodeStatsTable(&db);
    try createFtsTable(&db);
    try createIndexes(&db);
    try createTriggers(&db);

    try db.exec("COMMIT;", .{}, .{});
}
