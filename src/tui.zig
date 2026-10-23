const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");
const cmds = @import("cmds.zig");
const ctx = @import("ctx.zig");

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

const SearchInfo = struct {
    term: []const u8,
    regex: bool,
    case: bool,
};

const Match = extern struct {
    start: usize,
    end: usize,
};

extern fn regex_find_all_ffi(
    pattern: [*]const u8,
    pattern_len: usize,
    text: [*]const u8,
    text_len: usize,
    matches_out: **Match,
    len_out: *usize,
) callconv(.c) bool;

extern fn regex_free_matches(matches: [*]Match, len: usize) callconv(.c) void;

fn formatAgo(io: std.Io, alloc: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const diff = std.Io.Clock.real.now(io).toSeconds() - timestamp;
    if (diff < 60)
        return try alloc.print("{d}s ago", .{diff})
    else if (diff < 3600)
        return try alloc.print("{d}m ago", .{@divTrunc(diff, 60)})
    else if (diff < 86400)
        return try alloc.print("{d}h ago", .{@divTrunc(diff, 3600)})
    else if (diff < 31536000)
        return try alloc.print("{d}d ago", .{@divTrunc(diff, 86400)})
    else
        return try alloc.print("{d}y ago", .{@divTrunc(diff, 31536000)});
}

fn formatDuration(alloc: std.mem.Allocator, duration_ms: i64) ![]const u8 {
    if (duration_ms < 1000) {
        return try alloc.print("{d}ms", .{duration_ms});
    }

    const total_s = @divTrunc(duration_ms, 1000);

    if (total_s < 60) return try alloc.print("{d:.2}s", .{@as(f64, @floatFromInt(duration_ms)) / 1000.0});

    const s = @rem(total_s, 60);
    const total_m = @divTrunc(total_s, 60);

    if (total_m < 60) return try alloc.print("{d}m {d}s", .{ total_m, s });

    const m = @rem(total_m, 60);
    const total_h = @divTrunc(total_m, 60);

    if (total_h < 24) return try alloc.print("{d}h {d}m", .{ total_h, m });

    const h = @rem(total_h, 24);
    const d = @divTrunc(total_h, 24);
    return try alloc.print("{d}d {d}h", .{ d, h });
}

fn wrapCommand(alloc: std.mem.Allocator, content: []const u8, is_selected: bool, cmd_max_width: usize, search_info: ?SearchInfo) ![]const []const vaxis.Cell.Segment {
    const cmd_highlighted = try highlightZsh(alloc, content, is_selected, search_info);

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

fn highlightZsh(alloc: std.mem.Allocator, content: []const u8, is_selected: bool, search_info: ?SearchInfo) ![]vaxis.Cell.Segment {
    const sel_bg: vaxis.Color = if (is_selected) .{ .index = @backingInt(Colors.gray) } else .default;
    const styles = try alloc.alloc(vaxis.Style, content.len);
    defer alloc.free(styles);
    @memset(styles, .{ .bg = sel_bg });

    var token_it = cmds.ShellTokenIterator.init(content);
    var is_first_token = true;

    while (token_it.next()) |tr| {
        const token_text = content[tr.start..tr.end];
        var style: vaxis.Style = .{ .bg = sel_bg };

        if (is_first_token) {
            style.fg = .{ .index = @backingInt(Colors.green) };
            style.bold = true;
        } else if (std.mem.startsWith(u8, token_text, "-")) {
            style.fg = .{ .index = @backingInt(Colors.cyan) };
        } else if ((std.mem.startsWith(u8, token_text, "'") and std.mem.endsWith(u8, token_text, "'")) or
            (std.mem.startsWith(u8, token_text, "\"") and std.mem.endsWith(u8, token_text, "\"")))
        {
            style.fg = .{ .index = @backingInt(Colors.yellow) };
        }

        for (styles[tr.start..tr.end]) |*s| s.* = style;
        is_first_token = false;
    }

    var i: usize = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var escaped = false;

    while (i < content.len) {
        const c = content[i];

        if (escaped) {
            escaped = false;
            i += 1;
            continue;
        }

        if (c == '\\') {
            escaped = true;
            i += 1;
            continue;
        }

        if (!in_double_quote and c == '\'') {
            in_single_quote = !in_single_quote;
            i += 1;
            continue;
        }

        if (!in_single_quote and c == '"') {
            in_double_quote = !in_double_quote;
            i += 1;
            continue;
        }

        // Variables should not expand inside single quotes
        if (!in_single_quote) {
            var var_len: usize = 0;

            if (std.mem.startsWith(u8, content[i..], "${")) {
                for (content[i..], 0..) |char, j| {
                    if (char == '\\' and j + 1 < content[i..].len) continue;
                    if (char == '}') {
                        var_len = j + 1;
                        break;
                    }
                }
            } else if (std.mem.startsWith(u8, content[i..], "$(") or std.mem.startsWith(u8, content[i..], "<(")) {
                var depth: usize = 0;
                var in_q: ?u8 = null;
                for (content[i..], 0..) |char, j| {
                    if (char == '\\' and j + 1 < content[i..].len) continue;
                    if (in_q) |q| {
                        if (char == q) in_q = null;
                    } else if (char == '"' or char == '\'') {
                        in_q = char;
                    } else if (char == '(') {
                        depth += 1;
                    } else if (char == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            var_len = j + 1;
                            break;
                        }
                    }
                }
            } else if (c == '$') {
                var_len = 1;
                while (i + var_len < content.len) : (var_len += 1) {
                    const next_c = content[i + var_len];
                    if (!std.ascii.isAlphanumeric(next_c) and next_c != '_' and next_c != '?' and next_c != '!' and next_c != '*' and next_c != '@' and next_c != '#') break;
                }
            }

            if (var_len > 0) {
                for (styles[i .. i + var_len]) |*s| {
                    s.fg = .{ .index = @backingInt(Colors.magenta) };
                }
                i += var_len;
                continue;
            }
        }

        i += 1;
    }

    if (search_info) |info| {
        if (info.term.len > 0) {
            var matches_ptr: *Match = undefined;
            var len: usize = 0;

            const ok = regex_find_all_ffi(
                info.term.ptr,
                info.term.len,
                content.ptr,
                content.len,
                &matches_ptr,
                &len,
            );

            if (ok and len > 0) {
                const matches_many: [*]Match = @ptrCast(matches_ptr);
                defer regex_free_matches(matches_many, len);

                const matches = matches_many[0..len];
                for (matches) |m| {
                    if (m.end <= content.len) {
                        for (styles[m.start..m.end]) |*s| s.reverse = true;
                    }
                }
            }
        }
    }

    var segments: std.ArrayList(vaxis.Cell.Segment) = .empty;
    errdefer segments.deinit(alloc);

    if (content.len > 0) {
        var current_style = styles[0];
        var start_idx: usize = 0;
        for (styles, 0..) |s, j| {
            if (!std.meta.eql(s, current_style)) {
                try segments.append(alloc, .{ .text = content[start_idx..j], .style = current_style });
                current_style = s;
                start_idx = j;
            }
        }
        try segments.append(alloc, .{ .text = content[start_idx..], .style = current_style });
    }

    return try segments.toOwnedSlice(alloc);
}

inline fn parseSearch(term: []const u8) ?SearchInfo {
    var actual_search: []const u8 = "";
    var case_insensitive = false;

    if (term.len > 0) {
        actual_search = term;
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
        return SearchInfo{ .term = actual_search, .case = case_insensitive, .regex = regex };
    } else return null;
}

pub fn initTui(ctxi: *ctx.Ctx) !?[]const u8 {
    const alloc = ctxi.alloc;

    var buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(ctxi.io, &buf);
    defer tty.deinit();

    var vx = try vaxis.init(ctxi.io, alloc, &ctxi.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    const q = vaxis.Queue(Event, 512){ .io = ctxi.io };

    var loop: vaxis.Loop(Event) = .{
        .io = ctxi.io,
        .tty = &tty,
        .vaxis = &vx,
        .queue = q,
    };
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    var text_input = vaxis.widgets.TextInput.init(alloc);
    defer text_input.deinit();

    var db = ctxi.db orelse return error.DatabaseNotInitialized;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var history = try cmds.getCommands(arena.allocator(), &db, null);

    var selected_idx: i64 = 0;
    var scroll_offset: usize = 0;
    var displayed_screen: Screen = .history;

    var token_cursor: usize = 0;
    var sel_start: usize = 0;
    var sel_end: usize = 0;

    const style_dim: vaxis.Style = .{ .dim = true };
    const style_sep: vaxis.Style = .{ .fg = .{ .index = @backingInt(Colors.gray) }, .dim = true };
    const style_dur: vaxis.Style = .{ .fg = .{ .index = @backingInt(Colors.blue) } };

    while (true) {
        _ = arena.reset(.retain_capacity);
        const aa = arena.allocator();

        const win = vx.window();
        win.clear();
        const list_height = win.height - 3;

        const search = try std.mem.concat(aa, u8, &.{ text_input.buf.firstHalf(), text_input.buf.secondHalf() });

        const search_info = parseSearch(search);
        if (search_info) |info|
            history = try cmds.searchCommands(ctxi, aa, info.term, info.case, info.regex)
        else
            history = try cmds.getCommands(aa, &db, null);

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
                        const wrapped = try wrapCommand(aa, item.content, false, cmd_max_width, search_info);
                        total_lines_to_selection += wrapped.len;
                    }

                    while (total_lines_to_selection > usable_height and scroll_offset < @as(usize, @intCast(selected_idx))) {
                        const top_wrapped = try wrapCommand(aa, history[scroll_offset].content, false, cmd_max_width, search_info);
                        total_lines_to_selection -= top_wrapped.len;
                        scroll_offset += 1;
                    }
                }
            }

            for (history[scroll_offset..], 0..) |cmd, i| {
                if (y < 1) break;

                const current_item_idx = scroll_offset + i;
                const is_selected = (current_item_idx == selected_idx);
                const sel_bg: vaxis.Color = if (is_selected) .{ .index = @backingInt(Colors.gray) } else .default;

                const ago_str = try formatAgo(ctxi.io, aa, cmd.last_run_at);
                const dur_str = try formatDuration(aa, cmd.last_duration_ms);

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

                const ago_text = try aa.print("{s:>10} ", .{ago_str});
                const dur_text = try aa.print("{s:>8} ", .{dur_str});

                const wrapped = try wrapCommand(aa, cmd.content, is_selected, cmd_max_width, search_info);
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
            const tokens = try cmds.tokenizeCmd(aa, current_cmd);
            if (token_cursor >= tokens.len) {
                token_cursor = if (tokens.len > 0) tokens.len - 1 else 0;
            }
            if (sel_end >= tokens.len) {
                sel_end = if (tokens.len > 0) tokens.len - 1 else 0;
            }
            if (sel_start > sel_end) {
                sel_start = sel_end;
            }

            var seg_buf: std.ArrayList(u8) = .empty;
            for (tokens[sel_start .. sel_end + 1], 0..) |t, idx| {
                if (idx > 0) try seg_buf.append(aa, ' ');
                try seg_buf.appendSlice(aa, t);
            }
            const segment_str = try seg_buf.toOwnedSlice(aa);

            if (try cmds.getSegCmdInfo(aa, ctxi, segment_str)) |d| {
                var row: u16 = 1;
                const margin: u16 = 2;

                _ = detail_win.print(&.{
                    .{ .text = "COMMAND STATISTICS ", .style = .{ .bold = true, .fg = .{ .index = @backingInt(Colors.green) } } },
                }, .{ .row_offset = 0, .col_offset = 2 });

                var token_segs: std.ArrayList(vaxis.Cell.Segment) = .empty;
                for (tokens, 0..) |token, idx| {
                    if (idx > 0) {
                        try token_segs.append(aa, .{ .text = " ", .style = .{} });
                    }
                    var style: vaxis.Style = .{};
                    if (idx >= sel_start and idx <= sel_end) {
                        style.bg = .{ .index = @backingInt(Colors.blue) };
                        style.fg = .{ .index = 0 };
                    }
                    if (idx == token_cursor) {
                        style.ul_style = .single;
                        style.bold = true;
                    }
                    try token_segs.append(aa, .{ .text = token, .style = style });
                }
                _ = detail_win.print(token_segs.items, .{ .row_offset = row, .col_offset = margin + 1 });
                row += 2;

                _ = detail_win.print(&.{.{ .text = "Statistics:", .style = style_dim }}, .{ .row_offset = row, .col_offset = margin });
                row += 1;

                const stats_labels = [_][]const u8{ "Matching Cmds", "Run Count", "Total Time", "Avg Time", "Last Run" };

                const avg_dur = if (d.cmd_smry.run_count > 0) @divTrunc(d.cmd_smry.total_duration_ms, d.cmd_smry.run_count) else 0;

                const ago_str = try formatAgo(ctxi.io, aa, d.cmd_smry.last_run_at);
                const total_dur_str = try formatDuration(aa, d.cmd_smry.total_duration_ms);
                const avg_dur_str = try formatDuration(aa, avg_dur);

                const stats_values = [_][]const u8{
                    try aa.print("{d}", .{d.match_count}),
                    try aa.print("{d}", .{d.cmd_smry.run_count}),
                    total_dur_str,
                    avg_dur_str,
                    ago_str,
                };

                for (stats_labels, stats_values) |label, val| {
                    _ = detail_win.print(&.{
                        .{ .text = try aa.print("  {s: <14} ", .{label}), .style = style_sep },
                        .{ .text = val, .style = .{ .fg = .{ .index = @backingInt(Colors.cyan) } } },
                    }, .{ .row_offset = row, .col_offset = margin });
                    row += 1;
                }
                row += 1;

                _ = detail_win.print(&.{.{ .text = "Exit Codes (Frequency):", .style = style_dim }}, .{ .row_offset = row, .col_offset = margin });
                row += 1;

                for (d.exit_codes) |stat| {
                    const code_color: Colors = if (stat.exit_code == 0) .green else .yellow;
                    _ = detail_win.print(&.{
                        .{ .text = "  Code ", .style = style_sep },
                        .{ .text = try aa.print("{d: >3}", .{stat.exit_code}), .style = .{ .fg = .{ .index = @backingInt(code_color) } } },
                        .{ .text = " : ", .style = style_sep },
                        .{ .text = try aa.print("{d}", .{stat.frequency}), .style = .{} },
                    }, .{ .row_offset = row, .col_offset = margin });
                    row += 1;
                }
            }
        }

        try vx.render(tty.writer());
        const event = try loop.nextEvent();

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
                    try cmds.removeCommand(ctxi, history[@intCast(selected_idx)].content);
                } else if (key.matches('o', .{ .ctrl = true })) {
                    displayed_screen = .info;
                    token_cursor = 0;
                    sel_start = 0;
                    const current_cmd = history[@intCast(selected_idx)].content;
                    const init_tokens = try cmds.tokenizeCmd(aa, current_cmd);
                    sel_end = if (init_tokens.len > 0) init_tokens.len - 1 else 0;
                } else if (displayed_screen == .info) {
                    const current_cmd = history[@intCast(selected_idx)].content;
                    const tokens = try cmds.tokenizeCmd(aa, current_cmd);

                    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
                        if (token_cursor > 0) token_cursor -= 1;
                    } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
                        if (token_cursor + 1 < tokens.len) token_cursor += 1;
                    } else if (key.matches('[', .{})) {
                        sel_start = token_cursor;
                        if (sel_start > sel_end) sel_end = sel_start;
                    } else if (key.matches(']', .{})) {
                        sel_end = token_cursor;
                        if (sel_end < sel_start) sel_start = sel_end;
                    } else if (key.matches('a', .{})) {
                        sel_start = 0;
                        sel_end = if (tokens.len > 0) tokens.len - 1 else 0;
                    }
                } else if (displayed_screen == .history) {
                    try text_input.update(.{ .key_press = key });
                    selected_idx = 0;
                    scroll_offset = 0;
                }
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
    }
    try db_mod.maintenance(&db);
    return null;
}
