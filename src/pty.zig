const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("util.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
});

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,
    child_pid: ?posix.pid_t = null,

    pub const SpawnError = error{
        OpenPtyFailed,
        ForkFailed,
        SetsidFailed,
        ExecFailed,
    } || posix.WriteError;

    pub fn open() SpawnError!Pty {
        var master: posix.fd_t = undefined;
        var slave: posix.fd_t = undefined;
        if (c.openpty(&master, &slave, null, null, null) != 0) {
            return error.OpenPtyFailed;
        }
        return .{ .master = master, .slave = slave };
    }

    pub fn spawn(self: *Pty, argv: []const ?[*:0]const u8, env: ?[*:null]const ?[*:0]const u8) SpawnError!void {
        self.spawnCwd(argv, env, null);
    }

    pub fn spawnCwd(self: *Pty, argv: []const ?[*:0]const u8, env: ?[*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) SpawnError!void {
        const pid = posix.fork() catch return error.ForkFailed;

        if (pid == 0) {
            // Child process
            posix.close(self.master);

            _ = posix.setsid() catch {};

            // Set controlling terminal
            _ = c.ioctl(self.slave, c.TIOCSCTTY, @as(c_int, 0));

            // Change working directory if specified
            if (cwd) |dir| {
                _ = std.c.chdir(dir);
            }

            // Redirect stdio to slave PTY
            posix.dup2(self.slave, 0) catch {};
            posix.dup2(self.slave, 1) catch {};
            posix.dup2(self.slave, 2) catch {};

            if (self.slave > 2) posix.close(self.slave);

            const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv.ptr);
            const envp = env orelse @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
            const err = posix.execvpeZ(argv[0].?, argv_ptr, envp);
            _ = err catch {};
            posix.exit(1);
        }

        // Parent process
        posix.close(self.slave);
        self.slave = -1;
        self.child_pid = pid;
    }

    pub fn readMaster(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    pub fn writeMaster(self: *Pty, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            written += posix.write(self.master, data[written..]) catch |err| return err;
        }
    }

    pub fn setWindowSize(self: *Pty, rows: u16, cols: u16) void {
        var ws: c.struct_winsize = .{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = c.ioctl(self.master, c.TIOCSWINSZ, &ws);
    }

    pub fn isChildAlive(self: *Pty) bool {
        if (self.child_pid) |pid| {
            const result = posix.waitpid(pid, std.c.W.NOHANG);
            if (result.pid != 0) {
                self.child_pid = null;
                return false;
            }
            return true;
        }
        return false;
    }

    pub fn close(self: *Pty) void {
        if (self.child_pid) |pid| {
            posix.kill(pid, posix.SIG.TERM) catch {};
        }
        if (self.master >= 0) posix.close(self.master);
        if (self.slave >= 0) posix.close(self.slave);
    }
};

test "pty open" {
    var p = try Pty.open();
    defer p.close();
    try std.testing.expect(p.master >= 0);
    try std.testing.expect(p.slave >= 0);
}
