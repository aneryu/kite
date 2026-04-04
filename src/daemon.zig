const std = @import("std");
const posix = std.posix;

pub const PID_FILE_PATH = "/tmp/kite.pid";

pub const DaemonError = error{
    AlreadyRunning,
    WritePidFailed,
};

/// 检查 daemon 是否正在运行（通过 PID 文件和进程存活检测）
pub fn isRunning() bool {
    const pid = readPidFile() orelse return false;
    // 发送信号 0 检查进程是否存在
    posix.kill(pid, 0) catch return false;
    return true;
}

/// 写入 PID 文件
pub fn writePidFile() !void {
    const pid = std.c.getpid();
    const file = std.fs.createFileAbsolute(PID_FILE_PATH, .{ .truncate = true }) catch
        return error.WritePidFailed;
    defer file.close();
    var buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return error.WritePidFailed;
    file.writeAll(pid_str) catch return error.WritePidFailed;
}

/// 删除 PID 文件
pub fn removePidFile() void {
    std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};
}

/// 读取 PID 文件中的 PID
pub fn readPidFile() ?posix.pid_t {
    const file = std.fs.openFileAbsolute(PID_FILE_PATH, .{}) catch return null;
    defer file.close();
    var buf: [20]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    return std.fmt.parseInt(posix.pid_t, trimmed, 10) catch null;
}

test "pid file round trip" {
    // Clean up any existing file
    std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};
    defer std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};

    try writePidFile();
    const pid = readPidFile();
    try std.testing.expect(pid != null);
    try std.testing.expectEqual(std.c.getpid(), pid.?);

    // isRunning should return true for our own process
    try std.testing.expect(isRunning());

    removePidFile();
    try std.testing.expect(!isRunning());
}
