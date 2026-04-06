const std = @import("std");

var debug_enabled: bool = false;
var log_file: ?std.fs.File = null;

const LOG_PATH = "/tmp/kite.log";

pub fn init() void {
    debug_enabled = std.posix.getenv("KITE_DEBUG") != null;
    if (debug_enabled) {
        log_file = std.fs.createFileAbsolute(LOG_PATH, .{ .truncate = false }) catch null;
        if (log_file) |f| {
            f.seekFromEnd(0) catch {};
        }
    }
}

pub fn deinit() void {
    if (log_file) |f| {
        f.close();
    }
    log_file = null;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;

    const out = std.fmt.allocPrint(std.heap.page_allocator, fmt ++ "\n", args) catch return;
    defer std.heap.page_allocator.free(out);

    if (log_file) |f| {
        f.writeAll(out) catch {};
    }

    const stderr = std.fs.File.stderr();
    _ = stderr.write(out) catch {};
}
