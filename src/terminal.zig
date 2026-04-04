const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
});

var original_termios: ?std.c.termios = null;
var is_raw: bool = false;

pub fn enableRawMode(fd: posix.fd_t) !void {
    if (!posix.isatty(fd)) return error.NotATerminal;
    var raw = try posix.tcgetattr(fd);
    original_termios = raw;

    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.iflag.IXON = false;
    raw.iflag.IXOFF = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;

    raw.oflag.OPOST = false;

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, raw);
    is_raw = true;
}

pub fn restoreMode(fd: posix.fd_t) void {
    if (original_termios) |orig| {
        posix.tcsetattr(fd, .FLUSH, orig) catch {};
        original_termios = null;
        is_raw = false;
    }
}

pub const WinSize = struct {
    rows: u16,
    cols: u16,
};

pub fn getWindowSize(fd: posix.fd_t) ?WinSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &ws) == 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }
    return null;
}
