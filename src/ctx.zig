const std = @import("std");
const sqlite = @import("sqlite");

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: ?sqlite.Db = null,
    environ_map: std.process.Environ.Map,
    
    pub fn init(pinit: *const std.process.Init, allocator: std.mem.Allocator) !Ctx {
        return .{
            .allocator = allocator,
            .io = pinit.io,
            .environ_map = pinit.environ_map.*,
        };
    }
    
    pub fn deinit(self: *Ctx) void {
        if (self.db) |*db| {
            db.deinit();
        }
    }
};
