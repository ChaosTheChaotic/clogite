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

fn wrapCommand(alloc: std.mem.Allocator, content: []const u8, is_selected: bool, cmd_max_width: usize, search_term: []const u8, case_insensitive: bool) ![]const []const vaxis.Cell.Segment {
    const cmd_highlighted = try highlightZsh(alloc, content, is_selected, search_term, case_insensitive);

    var wrapped_lines: std.ArrayList([]const vaxis.Cell.Segment) = .empty;
    var current_line: std.ArrayList(vaxis.Cell.Segment) = .empty;
    var current_col: usize = 0;

    for (cmd_highlighted) |seg| {
        if (seg.text.len + current_col > cmd_max_width and current_col > 0) {
            if (std.mem.eql(u8, seg.text, " ")) {
                continue;
            }
            try wrapped_lines.append(alloc, try current_line.toOwnedSlice(alloc));
            current_line = .empty;
            current_col = 0;
        }

        var text_left = seg.text;
        while (text_left.len > 0) {
            const space_left = cmd_max_width - current_col;
            if (space_left == 0) {
                try wrapped_lines.append(alloc, try current_line.toOwnedSlice(alloc));
                current_line = .empty;
                current_col = 0;
                continue;
            }
            if (text_left.len <= space_left) {
                try current_line.append(alloc, .{ .text = text_left, .style = seg.style });
                current_col += text_left.len;
                break;
            } else {
                const chunk = text_left[0..space_left];
                try current_line.append(alloc, .{ .text = chunk, .style = seg.style });
                try wrapped_lines.append(alloc, try current_line.toOwnedSlice(alloc));
                current_line = .empty;
                current_col = 0;
                text_left = text_left[space_left..];
            }
        }
    }
    if (current_line.items.len > 0) {
        try wrapped_lines.append(alloc, try current_line.toOwnedSlice(alloc));
    }

    if (wrapped_lines.items.len == 0) {
        try wrapped_lines.append(alloc, &.{});
    }

    return try wrapped_lines.toOwnedSlice(alloc);
}

fn highlightZsh(allocator: std.mem.Allocator, content: []const u8, is_selected: bool, search_term: []const u8, case_insensitive: bool) ![]vaxis.Cell.Segment {
    const sel_bg: vaxis.Color = if (is_selected) .{ .index = @intFromEnum(Colors.gray) } else .default;

    const styles = try allocator.alloc(vaxis.Style, content.len);
    defer allocator.free(styles);
    @memset(styles, .{ .bg = sel_bg });

    var tokens = std.mem.tokenizeAny(u8, content, " ");
    var is_first = true;

    while (tokens.next()) |token| {
        const start = @intFromPtr(token.ptr) - @intFromPtr(content.ptr);
        var style: vaxis.Style = .{ .bg = sel_bg };

        if (is_first) {
            style.fg = .{ .index = @intFromEnum(Colors.green) };
            style.bold = true;
        } else if (std.mem.startsWith(u8, token, "-")) {
            style.fg = .{ .index = @intFromEnum(Colors.cyan) };
        } else if (std.mem.startsWith(u8, token, "\"") or std.mem.startsWith(u8, token, "'")) {
            style.fg = .{ .index = @intFromEnum(Colors.yellow) };
        } else if (std.mem.startsWith(u8, token, "$")) {
            style.fg = .{ .index = @intFromEnum(Colors.magenta) };
        }

        for (styles[start .. start + token.len]) |*s| {
            s.* = style;
        }
        is_first = false;
    }

    if (search_term.len > 0) {
        var i: usize = 0;
        while (i < content.len) {
            const slice = content[i..];
            const match_offset = if (case_insensitive)
                std.ascii.indexOfIgnoreCase(slice, search_term)
            else
                std.mem.indexOf(u8, slice, search_term);

            if (match_offset) |offset| {
                const idx = i + offset;
                for (styles[idx .. idx + search_term.len]) |*s| {
                    s.reverse = true;
                }
                i = idx + search_term.len;
            } else {
                break;
            }
        }
    }

    var segments: std.ArrayList(vaxis.Cell.Segment) = .empty;
    errdefer segments.deinit(allocator);

    if (content.len > 0) {
        var current_style = styles[0];
        var start_idx: usize = 0;
        for (styles, 0..) |s, i| {
            if (!std.meta.eql(s, current_style)) {
                try segments.append(allocator, .{
                    .text = content[start_idx..i],
                    .style = current_style,
                });
                current_style = s;
                start_idx = i;
            }
        }
        try segments.append(allocator, .{
            .text = content[start_idx..],
            .style = current_style,
        });
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

        const search = try std.mem.concat(aa, u8, &.{ text_input.buf.firstHalf(), text_input.buf.secondHalf() });

        var actual_search: []const u8 = "";
        var case_insensitive = false;

        if (search.len > 0) {
            actual_search = search;
            var regex = true;

            while (actual_search.len >= 2 and actual_search[0] == '\\') {
                if (actual_search[1] == 'c') {
                    case_insensitive = true;
                    actual_search = actual_search[2..];
                } else if (actual_search[1] == 'f') {
                    regex = false;
                    actual_search = actual_search[2..];
                } else break;
            }

            history = try cmds.searchCommands(aa, db, actual_search, case_insensitive, regex);
        } else {
            history = try cmds.getCommands(aa, db, null);
        }

        if (displayed_screen == .history) {
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

            const usable_height = if (list_win.height > 2) list_win.height - 2 else 0;

            const now = std.time.timestamp();
            var y: i32 = @as(i32, @intCast(list_win.height)) - 2;

            const prefix_width: usize = 24; // ago (11) + sep (2) + dur (9) + sep (2)
            const cmd_max_width: usize = if (list_win.width > prefix_width) list_win.width - prefix_width else 1;

            if (history.len > 0) {
                if (selected_idx >= @as(i64, @intCast(history.len))) {
                    selected_idx = @as(i64, @intCast(history.len)) - 1;
                }
                if (selected_idx < 0) selected_idx = 0;

                if (selected_idx < scroll_offset) {
                    scroll_offset = @intCast(selected_idx);
                } else {
                    var total_lines_to_selection: usize = 0;
                    for (history[scroll_offset..@intCast(selected_idx + 1)]) |item| {
                        const wrapped = try wrapCommand(aa, item.content, false, cmd_max_width, actual_search, case_insensitive);
                        total_lines_to_selection += wrapped.len;
                    }

                    while (total_lines_to_selection > usable_height and scroll_offset < @as(usize, @intCast(selected_idx))) {
                        const top_wrapped = try wrapCommand(aa, history[scroll_offset].content, false, cmd_max_width, actual_search, case_insensitive);
                        total_lines_to_selection -= top_wrapped.len;
                        scroll_offset += 1;
                    }
                }
            }

            for (history[scroll_offset..], 0..) |cmd, i| {
                if (y < 1) break;

                const current_item_idx = scroll_offset + i;
                const is_selected = (current_item_idx == selected_idx);
                const sel_bg: vaxis.Color = if (is_selected) .{ .index = @intFromEnum(Colors.gray) } else .default;

                var ago_buf: [32]u8 = undefined;
                var dur_buf: [32]u8 = undefined;
                const diff = now - cmd.last_run_at;
                const ago_str = if (diff < 60) try std.fmt.bufPrint(&ago_buf, "{d}s ago", .{diff}) else if (diff < 3600) try std.fmt.bufPrint(&ago_buf, "{d}m ago", .{@divTrunc(diff, 60)}) else if (diff < 86400) try std.fmt.bufPrint(&ago_buf, "{d}h ago", .{@divTrunc(diff, 3600)}) else try std.fmt.bufPrint(&ago_buf, "{d}d ago", .{@divTrunc(diff, 86400)});
                const dur_str = if (cmd.last_duration_ms < 1000)
                    try std.fmt.bufPrint(&dur_buf, "{d}ms", .{cmd.last_duration_ms})
                else
                    try std.fmt.bufPrint(&dur_buf, "{d:.2}s", .{@as(f64, @floatFromInt(cmd.last_duration_ms)) / 1000.0});

                var base_ago = style_dim;
                var base_dur = style_dur;
                var base_sep = style_sep;

                if (is_selected) {
                    base_ago.dim = false;
                    base_dur.dim = false;
                    base_sep.dim = false;
                }

                base_ago.bg = sel_bg;
                base_dur.bg = sel_bg;
                base_sep.bg = sel_bg;

                const ago_text = try std.fmt.allocPrint(aa, "{s:>10} ", .{ago_str});
                const dur_text = try std.fmt.allocPrint(aa, "{s:>8} ", .{dur_str});

                const wrapped = try wrapCommand(aa, cmd.content, is_selected, cmd_max_width, actual_search, case_insensitive);
                const lines_count = wrapped.len;

                for (wrapped, 0..) |line_segs, l| {
                    const draw_y = y - @as(i32, @intCast(lines_count)) + 1 + @as(i32, @intCast(l));
                    if (draw_y < 0 or draw_y >= list_win.height) continue;

                    var line_segments: std.ArrayList(vaxis.Cell.Segment) = .empty;

                    if (l == 0) {
                        try line_segments.append(aa, .{ .text = ago_text, .style = base_ago });
                        try line_segments.append(aa, .{ .text = "│ ", .style = base_sep });
                        try line_segments.append(aa, .{ .text = dur_text, .style = base_dur });
                        try line_segments.append(aa, .{ .text = "│ ", .style = base_sep });
                    } else {
                        const padding = try aa.alloc(u8, prefix_width);
                        @memset(padding, ' ');
                        try line_segments.append(aa, .{ .text = padding, .style = .{ .bg = sel_bg } });
                    }

                    try line_segments.appendSlice(aa, line_segs);

                    var total_width: usize = prefix_width;
                    for (line_segs) |seg| total_width += seg.text.len;

                    if (is_selected and total_width < list_win.width) {
                        const padding = try aa.alloc(u8, list_win.width - total_width);
                        @memset(padding, ' ');
                        try line_segments.append(aa, .{ .text = padding, .style = .{ .bg = sel_bg } });
                    }

                    _ = list_win.print(line_segments.items, .{ .row_offset = @intCast(draw_y), .col_offset = 0 });
                }

                y -= @as(i32, @intCast(lines_count));
            }

            text_input.draw(search_win);
        } else {
            const detail_win = win.child(.{
                .x_off = 4,
                .y_off = 2,
                .width = if (win.width > 10) win.width - 8 else win.width,
                .height = if (win.height > 6) win.height - 4 else win.height,
                .border = .{ .where = .all, .style = style_sep },
            });

            const current_cmd = history[@intCast(selected_idx)].content;
            if (try cmds.getCommandInfo(aa, db, current_cmd)) |d| {
                var row: i32 = 1;
                const margin: u16 = 2;

                _ = detail_win.print(&.{.{ .text = " COMMAND DETAILS ", .style = .{ .reverse = true, .bold = true } }}, .{ .row_offset = @intCast(row), .col_offset = margin });
                row += 2;

                _ = detail_win.print(&.{.{ .text = "COMMAND:", .style = .{ .bold = true, .fg = .{ .index = @intFromEnum(Colors.cyan) } } }}, .{ .row_offset = @intCast(row), .col_offset = margin });
                row += 1;

                const cmd_width = if (detail_win.width > margin * 2) detail_win.width - (margin * 2) else 1;
                const wrapped = try wrapCommand(aa, d.cmd.content, false, cmd_width, actual_search, case_insensitive);
                for (wrapped) |line_segs| {
                    if (row >= detail_win.height - 1) break;
                    _ = detail_win.print(line_segs, .{ .row_offset = @intCast(row), .col_offset = margin });
                    row += 1;
                }
                row += 1;

                if (row < detail_win.height - 1) {
                    _ = detail_win.print(&.{.{ .text = "STATISTICS:", .style = .{ .bold = true, .fg = .{ .index = @intFromEnum(Colors.cyan) } } }}, .{ .row_offset = @intCast(row), .col_offset = margin });
                    row += 1;

                    const avg_dur = @as(f64, @floatFromInt(d.cmd.total_duration_ms)) / @as(f64, @floatFromInt(@max(1, d.cmd.run_count)));

                    const stats = [_]struct { label: []const u8, value: []const u8, style: vaxis.Style }{
                        .{ .label = "Total Runs:     ", .value = try std.fmt.allocPrint(aa, "{d}", .{d.cmd.run_count}), .style = .{} },
                        .{ .label = "Avg Duration:   ", .value = try std.fmt.allocPrint(aa, "{d:.2}ms", .{avg_dur}), .style = style_dur },
                        .{ .label = "Last Exit Code: ", .value = try std.fmt.allocPrint(aa, "{d}", .{d.cmd.last_exit_code}), .style = if (d.cmd.last_exit_code == 0) .{ .fg = .{ .index = 2 } } else .{ .fg = .{ .index = 1 } } },
                    };

                    for (stats) |stat| {
                        if (row >= detail_win.height - 1) break;
                        var line: std.ArrayList(vaxis.Cell.Segment) = .empty;
                        try line.append(aa, .{ .text = stat.label, .style = style_dim });
                        try line.append(aa, .{ .text = stat.value, .style = stat.style });
                        _ = detail_win.print(line.items, .{ .row_offset = @intCast(row), .col_offset = margin });
                        row += 1;
                    }
                }
                row += 1;

                if (row < detail_win.height - 2) {
                    _ = detail_win.print(&.{.{ .text = "EXIT CODE FREQUENCY:", .style = .{ .bold = true, .fg = .{ .index = @intFromEnum(Colors.cyan) } } }}, .{ .row_offset = @intCast(row), .col_offset = margin });
                    row += 1;

                    for (d.exit_codes) |ec| {
                        if (row >= detail_win.height - 2) break;
                        const ec_style: vaxis.Style = if (ec.exit_code == 0) .{ .fg = .{ .index = 2 } } else .{ .fg = .{ .index = 1 } };
                        const ec_text = try std.fmt.allocPrint(aa, "  Code {d:3} : {d} times", .{ ec.exit_code, ec.frequency });
                        _ = detail_win.print(&.{.{ .text = ec_text, .style = ec_style }}, .{ .row_offset = @intCast(row), .col_offset = margin });
                        row += 1;
                    }
                }

                const footer_style = style_dim;
                _ = detail_win.print(&.{.{ .text = " [ESC] Back ", .style = footer_style }}, .{ .row_offset = @intCast(detail_win.height - 1), .col_offset = margin });
            }
        }

        try vx.render(tty.writer());
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches(vaxis.Key.escape, .{})) {
                    if (displayed_screen == .history) break else displayed_screen = .history;
                } else if (key.matches(vaxis.Key.up, .{}) and displayed_screen == .history) {
                    if (history.len > 0 and selected_idx < history.len - 1) selected_idx += 1;
                } else if (key.matches(vaxis.Key.down, .{}) and displayed_screen == .history) {
                    if (selected_idx > 0) selected_idx -= 1 else break;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    const cmd = history[@intCast(selected_idx)].content;
                    return try std.mem.concat(alloc, u8, &.{ "\x1E", cmd });
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    const cmd = history[@intCast(selected_idx)].content;
                    return try std.mem.concat(alloc, u8, &.{ "\x1F", cmd });
                } else if (key.matches('d', .{ .ctrl = true })) {
                    try cmds.removeCommand(db, history[@intCast(selected_idx)].content);
                } else if (key.matches('o', .{ .ctrl = true })) {
                    displayed_screen = .info;
                } else if (displayed_screen == .history) {
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
