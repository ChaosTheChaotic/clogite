const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");
const cmds = @import("cmds.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

pub fn initTui(db: *sqlite.Db) !?[]const u8 {
    const alloc = std.heap.smp_allocator;

    var buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buf);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };

    try loop.init();

    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    var text_input = vaxis.widgets.TextInput.init(alloc);
    defer text_input.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var history = try cmds.getCommands(arena.allocator(), db, null);

    var selected_idx: i64 = 0;
    var scroll_offset: usize = 0;

    while (true) {
        _ = arena.reset(.retain_capacity);

        const win = vx.window();
        const list_height = win.height - 3;

        var search = text_input.sliceToCursor(&buf);
        if (search.len > 0) {
            const caseInsensitive = std.mem.startsWith(u8, search, "\\c");
            const actual_search = if (caseInsensitive) search[2..] else search;
            history = try cmds.searchCommands(alloc, db, actual_search, caseInsensitive);
        } else {
            history = try cmds.getCommands(alloc, db, null);
        }

        win.clear();
        const search_win = win.child(.{
            .x_off = 0,
            .y_off = win.height - 3,
            .height = 3,
            .border = .{ .where = .all },
        });

        const list_win = win.child(.{
            .x_off = 0,
            .y_off = 0,
            .height = list_height,
            .border = .{ .where = .all },
        });

        const now = std.time.timestamp();
        var y: i32 = @as(i32, list_win.height) - 1;

        const end_idx = @min(history.len, scroll_offset + list_win.height);
        const visible_history = history[scroll_offset..end_idx];

        for (visible_history, 0..) |cmd, i| {
            if (y < 0) break;

            const current_item_idx = scroll_offset + i;
            var ago_buf: [32]u8 = undefined;
            var dur_buf: [32]u8 = undefined;

            const diff = now - cmd.last_run_at;
            const ago_str = if (diff < 60) std.fmt.bufPrint(&ago_buf, "{d}s ago", .{diff}) catch "now" else if (diff < 3600) std.fmt.bufPrint(&ago_buf, "{d}m ago", .{@divTrunc(diff, 60)}) catch "" else if (diff < 86400) std.fmt.bufPrint(&ago_buf, "{d}h ago", .{@divTrunc(diff, 3600)}) catch "" else std.fmt.bufPrint(&ago_buf, "{d}d ago", .{@divTrunc(diff, 86400)}) catch "";

            const dur_str = if (cmd.last_duration_ms < 1000)
                std.fmt.bufPrint(&dur_buf, "{d}ms", .{cmd.last_duration_ms}) catch ""
            else
                std.fmt.bufPrint(&dur_buf, "{d:.2}s", .{@as(f64, @floatFromInt(cmd.last_duration_ms)) / 1000.0}) catch "";

            const line = try std.fmt.allocPrint(arena.allocator(), "{s:>10} │ {s:>8} │ {s}", .{ ago_str, dur_str, cmd.content });

            const style: vaxis.Style = if (current_item_idx == selected_idx) .{ .reverse = true } else .{};

            _ = list_win.print(&.{.{ .text = line, .style = style }}, .{ .row_offset = @intCast(y), .col_offset = 0 });
            y -= 1;
        }

        text_input.draw(search_win);
        try vx.render(tty.writer());

        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches(vaxis.Key.up, .{})) {
                    if (history.len > 0 and selected_idx < history.len - 1) {
                        selected_idx += 1;
                        if (selected_idx >= scroll_offset + list_height) {
                            scroll_offset += 1;
                        }
                    }
                } else if (key.matches(vaxis.Key.down, .{})) {
                    if (selected_idx > 0) {
                        selected_idx -= 1;
                        if (selected_idx < scroll_offset) {
                            scroll_offset -= 1;
                        }
                    } else break;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    return try alloc.dupe(u8, history[@intCast(selected_idx)].content);
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    // TODO: Run the command and exit null
                    // Define argv and use exec? to replace program or spwan and detach
                } else {
                    try text_input.update(.{ .key_press = key });
                    selected_idx = 0;
                    scroll_offset = 0;
                }
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
    }
    try db_mod.maintenance(db);
    return null;
}
