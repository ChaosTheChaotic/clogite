const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");
const cmds = @import("cmds.zig");

const Colors = enum(u8) {
    green = 2,
    cyan = 6,
    yellow = 3,
    magenta = 5,
    gray = 8,
    blue = 4,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Screen = enum {
    history,
    info,
};

fn highlightZsh(allocator: std.mem.Allocator, content: []const u8, is_selected: bool) ![]vaxis.Cell.Segment {
    var segments: std.ArrayList(vaxis.Cell.Segment) = .empty;
    errdefer segments.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, content, " ");
    var is_first = true;

    while (tokens.next()) |token| {
        if (!is_first) {
            try segments.append(allocator, .{ .text = " ", .style = .{} });
        }

        const style: vaxis.Style = blk: {
            if (is_first) {
                break :blk .{ .fg = .{ .index = @intFromEnum(Colors.green) }, .bold = true };
            } else if (std.mem.startsWith(u8, token, "-")) {
                break :blk .{ .fg = .{ .index = @intFromEnum(Colors.cyan) } };
            } else if (std.mem.startsWith(u8, token, "\"") or std.mem.startsWith(u8, token, "'")) {
                break :blk .{ .fg = .{ .index = @intFromEnum(Colors.yellow) } };
            } else if (std.mem.startsWith(u8, token, "$")) {
                break :blk .{ .fg = .{ .index = @intFromEnum(Colors.magenta) } };
            }
            break :blk .{};
        };

        var final_style = style;
        if (is_selected) final_style.reverse = true;

        try segments.append(allocator, .{ .text = token, .style = final_style });
        is_first = false;
    }

    return try segments.toOwnedSlice(allocator);
}

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
    var displayed_screen: Screen = .history;

    const style_dim: vaxis.Style = .{ .dim = true };
    const style_sep: vaxis.Style = .{ .fg = .{ .index = @intFromEnum(Colors.gray) }, .dim = true };
    const style_dur: vaxis.Style = .{ .fg = .{ .index = @intFromEnum(Colors.blue) } };

    while (true) {
        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();
        
        const win = vx.window();
        win.clear();
        const list_height = win.height - 3;

        if (displayed_screen == .history) {
            const search = text_input.sliceToCursor(&buf);
            if (search.len > 0) {
                const caseInsensitive = std.mem.startsWith(u8, search, "\\c");
                const actual_search = if (caseInsensitive) search[2..] else search;
                history = try cmds.searchCommands(aa, db, actual_search, caseInsensitive);
            } else {
                history = try cmds.getCommands(aa, db, null);
            }

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
                const is_selected = (current_item_idx == selected_idx);

                var ago_buf: [32]u8 = undefined;
                var dur_buf: [32]u8 = undefined;
                const diff = now - cmd.last_run_at;
                
                const ago_str = if (diff < 60) try std.fmt.bufPrint(&ago_buf, "{d}s ago", .{diff}) else if (diff < 3600) try std.fmt.bufPrint(&ago_buf, "{d}m ago", .{@divTrunc(diff, 60)}) else if (diff < 86400) try std.fmt.bufPrint(&ago_buf, "{d}h ago", .{@divTrunc(diff, 3600)}) else try std.fmt.bufPrint(&ago_buf, "{d}d ago", .{@divTrunc(diff, 86400)});

                const dur_str = if (cmd.last_duration_ms < 1000)
                    try std.fmt.bufPrint(&dur_buf, "{d}ms", .{cmd.last_duration_ms})
                else
                    try std.fmt.bufPrint(&dur_buf, "{d:.2}s", .{@as(f64, @floatFromInt(cmd.last_duration_ms)) / 1000.0});

                // Build line segments
                var line_segments: std.ArrayList(vaxis.Cell.Segment) = .empty;
                
                var base_ago = style_dim;
                var base_dur = style_dur;
                var base_sep = style_sep;
                if (is_selected) {
                    base_ago.reverse = true;
                    base_dur.reverse = true;
                    base_sep.reverse = true;
                }

                try line_segments.append(aa, .{ .text = try std.fmt.allocPrint(aa, "{s:>10} ", .{ago_str}), .style = base_ago });
                try line_segments.append(aa, .{ .text = "│ ", .style = base_sep });
                try line_segments.append(aa, .{ .text = try std.fmt.allocPrint(aa, "{s:>8} ", .{dur_str}), .style = base_dur });
                try line_segments.append(aa, .{ .text = "│ ", .style = base_sep });
                
                const cmd_highlighted = try highlightZsh(aa, cmd.content, is_selected);
                try line_segments.appendSlice(aa, cmd_highlighted);

                _ = list_win.print(line_segments.items, .{ .row_offset = @intCast(y), .col_offset = 0 });
                y -= 1;
            }

            text_input.draw(search_win);
        } else {
            const detail_win = win.child(.{
                .x_off = 4,
                .y_off = 2,
                .width = if (win.width > 10) win.width - 8 else win.width,
                .height = if (win.height > 6) win.height - 4 else win.height,
                .border = .{ .where = .all },
            });
            const current_cmd = history[@intCast(selected_idx)].content;
            if (try cmds.getCommandInfo(aa, db, current_cmd)) |d| {
                var row: u16 = 1;
                _ = detail_win.print(&.{.{ .text = " COMMAND DETAILS ", .style = .{ .reverse = true, .bold = true } }}, .{ .row_offset = row, .col_offset = 2 });
                row += 2;
                _ = detail_win.print(&.{.{ .text = try std.fmt.allocPrint(aa, "Content: {s}", .{d.cmd.content}) }}, .{ .row_offset = row, .col_offset = 2 });
                row += 2;
                _ = detail_win.print(&.{.{ .text = try std.fmt.allocPrint(aa, "Runs:     {d}", .{d.cmd.run_count}), .style = style_dur }}, .{ .row_offset = row, .col_offset = 2 });
                row += 1;
                const avg = @as(f64, @floatFromInt(d.cmd.total_duration_ms)) / @as(f64, @floatFromInt(@max(1, d.cmd.run_count)));
                _ = detail_win.print(&.{.{ .text = try std.fmt.allocPrint(aa, "Avg Dur:  {d:.2}ms", .{avg}), .style = style_dur }}, .{ .row_offset = row, .col_offset = 2 });
                row += 2;
                _ = detail_win.print(&.{.{ .text = "EXIT CODE STATS:", .style = .{ .bold = true } }}, .{ .row_offset = row, .col_offset = 2 });
                row += 1;
                for (d.exit_codes) |ec| {
                    const ec_style: vaxis.Style = if (ec.exit_code == 0) .{ .fg = .{ .index = 2 } } else .{ .fg = .{ .index = 1 } };
                    _ = detail_win.print(&.{.{ .text = try std.fmt.allocPrint(aa, "  Code {d:3} : {d} times", .{ec.exit_code, ec.frequency}), .style = ec_style }}, .{ .row_offset = row, .col_offset = 2 });
                    row += 1;
                }
                _ = detail_win.print(&.{.{ .text = "Press ESC to return", .style = style_dim }}, .{ .row_offset = @intCast(detail_win.height - 2), .col_offset = 2 });
            }
        }
        
        try vx.render(tty.writer());
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    if (displayed_screen == .history) break else displayed_screen = .history;
                } else if (key.matches(vaxis.Key.up, .{}) and displayed_screen == .history) {
                    if (history.len > 0 and selected_idx < history.len - 1) {
                        selected_idx += 1;
                        if (selected_idx >= scroll_offset + list_height) scroll_offset += 1;
                    }
                } else if (key.matches(vaxis.Key.down, .{}) and displayed_screen == .history) {
                    if (selected_idx > 0) {
                        selected_idx -= 1;
                        if (selected_idx < scroll_offset) scroll_offset -= 1;
                    } else break;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    const cmd = history[@intCast(selected_idx)].content;
                    return try std.fmt.allocPrint(alloc, "print -z '{s}'", .{cmd});
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    const cmd = history[@intCast(selected_idx)].content;
                    try vx.exitAltScreen(tty.writer());
                    return try alloc.dupe(u8, cmd);
                } else if (key.matches('d', .{ .ctrl = true })) {
                    try cmds.removeCommand(db, history[@intCast(selected_idx)].content);
                } else if (key.matches('o', .{ .ctrl = true })) {
                    displayed_screen = .info;
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
