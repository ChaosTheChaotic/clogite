const std = @import("std");
const vaxis = @import("vaxis");
const sqlite = @import("sqlite");
const db_mod = @import("db.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn initTui(db: *sqlite.Db) !void {
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

    // Starts read loop, puts terminal in raw mode and reads user input
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());

    var text_input = vaxis.widgets.TextInput.init(alloc);
    defer text_input.deinit();

    while (true) {
        const event = loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else {
                    try text_input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
            else => {},
        }
        const win = vx.window();

        win.clear();

        const search = win.child(.{
            .x_off = 0,
            .y_off = win.height - 3,
            .height = 3,
            .border = .{
                .where = .all,
            },
        });

        text_input.draw(search);
        try vx.render(tty.writer());
    }
    try db_mod.maintenance(db);
}
