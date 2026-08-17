const std = @import("std");
pub const sqlite = @import("sqlite");
const program_info = @import("program_info");
const clogite = @import("root.zig");

const c = sqlite.c;

extern fn sqlite3_sqlitezstd_init(
    db: ?*c.sqlite3,
    pz_err_msg: ?*?[*c]u8,
    p_api: ?*c.sqlite3_api_routines,
) callconv(.c) c_int;

extern fn sqlite3_regex_init(
    db: ?*c.sqlite3,
    pz_err_msg: ?*?[*c]u8,
    p_api: ?*c.sqlite3_api_routines,
) callconv(.c) c_int;

pub inline fn getDbPath(ctx: clogite.ctx.Ctx) [:0]const u8 {
    const alloc = ctx.alloc;
    const data_dir = clogite.getAppDataDir(ctx, program_info.program_name) catch |e| blk: {
        std.log.err("Error getting app data path: {}", .{e});
        std.log.warn("Falling back to cwd", .{});
        break :blk std.Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", alloc) catch |fe| {
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

pub inline fn checkDbSize(ctx: clogite.ctx.Ctx, db_path: ?[:0]const u8) bool {
    const alloc = ctx.alloc;
    const path = db_path orelse getDbPath(ctx);
    defer if (db_path == null) alloc.free(path);

    const fp = std.Io.Dir.openFileAbsolute(ctx.io, path, .{}) catch |e| {
        std.log.err("Failed to open database at {s} to verify size: {t}", .{ path, e });
        return false;
    };
    defer fp.close(ctx.io);

    const stat = fp.stat(ctx.io) catch |e| {
        std.log.err("Failed to stat file at {s}: {t}", .{ path, e });
        return false;
    };
    return stat.size > 0;
}

pub inline fn checkDbExists(ctx: clogite.ctx.Ctx, db_path: ?[:0]const u8) bool {
    const alloc = ctx.alloc;
    const path = db_path orelse getDbPath(ctx);
    defer if (db_path == null) alloc.free(path);
    std.Io.Dir.accessAbsolute(ctx.io, path, .{}) catch {
        return false;
    };
    return true;
}

fn createCommandsTable(db: *sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS commands (
        \\    id INTEGER PRIMARY KEY,
        \\    content TEXT NOT NULL, -- UNIQUE removed so it can be compressed
        \\    content_hash BLOB UNIQUE NOT NULL, -- Used for uniqueness
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

fn applyPragmas(db: *sqlite.Db) !void {
    _ = try db.pragma(void, .{}, "journal_mode", "WAL");
    _ = try db.pragma(void, .{}, "synchronous", "NORMAL");
    _ = try db.pragma(void, .{}, "temp_store", "MEMORY");
    _ = try db.pragma(void, .{}, "busy_timeout", "5000");
    _ = try db.pragma(void, .{}, "auto_vacuum", "full");
}

fn enableZstdCompression(db: *sqlite.Db) !void {
    var transp_stmt = try db.prepare(
        \\SELECT zstd_enable_transparent('{"table": "commands", "column": "content", "compression_level": 19, "dict_chooser": "''a''"}');
    );
    defer transp_stmt.deinit();

    var incmnt_stmt = try db.prepare("SELECT zstd_incremental_maintenance(null, 1);");
    defer incmnt_stmt.deinit();

    try db.exec("VACUUM;", .{}, .{});
}

pub fn maintenance(db: *sqlite.Db) !void {
    var incmt_stmt = try db.prepare("SELECT zstd_incremental_maintenance(null, 1);");
    defer incmt_stmt.deinit();
    try db.exec("VACUUM;", .{}, .{});

    try db.exec("INSERT INTO commands_fts(commands_fts) VALUES('optimize');", .{}, .{});
}

pub fn initDb(ctx: clogite.ctx.Ctx) !sqlite.Db {
    const db_path = getDbPath(ctx);

    const rcz = c.sqlite3_auto_extension(@ptrCast(&sqlite3_sqlitezstd_init));
    if (rcz != c.SQLITE_OK) {
        std.log.err("Failed to register sqlite-zstd auto-extension. SQLite error code: {d}", .{rcz});
        return error.ExtensionRegistrationFailed;
    }
    const rcr = c.sqlite3_auto_extension(@ptrCast(&sqlite3_regex_init));
    if (rcr != c.SQLITE_OK) {
        std.log.err("Failed to register sqlite-regex auto-extension. SQLite error code: {d}", .{rcr});
        return error.ExtensionRegistrationFailed;
    }

    if (checkDbExists(ctx, db_path) and checkDbSize(ctx, db_path)) {
        var db = try sqlite.Db.init(.{
            .mode = .{ .File = db_path },
            .open_flags = .{ .write = true },
            .threading_mode = .MultiThread,
        });
        try applyPragmas(&db);
        try maintenance(&db);
        return db;
    }

    if (std.fs.path.dirname(db_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch |e| {
            std.log.err("Failed to create directory {s}: {}", .{ dir, e });
        };
    }

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = db_path },
        .open_flags = .{ .create = true, .write = true },
        .threading_mode = .MultiThread,
    });
    try applyPragmas(&db);
    try db.exec("BEGIN TRANSACTION;", .{}, .{});

    try createCommandsTable(&db);
    try createExitCodeStatsTable(&db);
    try createFtsTable(&db);
    try createIndexes(&db);
    try createTriggers(&db);

    try db.exec("COMMIT;", .{}, .{});

    try enableZstdCompression(&db);
    try maintenance(&db);
    return db;
}
