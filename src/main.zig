const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const Session = @import("session.zig").Session;
const Auth = @import("auth.zig").Auth;
const auth_mod = @import("auth.zig");
const HttpServer = @import("http.zig").Server;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const hooks = @import("hooks.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");

const Config = struct {
    port: u16 = 7890,
    bind: []const u8 = "0.0.0.0",
    command: []const u8 = "claude",
};

const Command = enum {
    start,
    hook,
    setup,
    status,
    help,
};

var global_pty: ?*Pty = null;
var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onTerminalInput(data: []const u8) void {
    if (global_pty) |p| {
        p.writeMaster(data) catch {};
    }
}

fn onResize(rows: u16, cols: u16) void {
    if (global_pty) |p| {
        p.setWindowSize(rows, cols);
    }
}

fn handleSigwinch(_: c_int) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn syncWindowSize() void {
    if (global_pty) |p| {
        if (terminal.getWindowSize(posix.STDIN_FILENO)) |ws| {
            p.setWindowSize(ws.rows, ws.cols);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = parseCommand(args[1]) orelse {
        printUsage();
        return;
    };

    switch (cmd) {
        .start => try runStart(allocator, args[2..]),
        .hook => try runHook(allocator, args[2..]),
        .setup => try runSetup(allocator),
        .status => try runStatus(),
        .help => printUsage(),
    }
}

fn parseCommand(arg: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "start", .start },
        .{ "hook", .hook },
        .{ "setup", .setup },
        .{ "status", .status },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return map.get(arg);
}

fn runStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 7890;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            config.bind = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--cmd") and i + 1 < args.len) {
            config.command = args[i + 1];
            i += 1;
        }
    }

    const stdin_fd = posix.STDIN_FILENO;
    const stdout_fd = posix.STDOUT_FILENO;
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Initialize auth
    var auth = Auth.init();
    const setup_hex = auth.getSetupTokenHex();

    try stdout.print("\n  kite - AI Coding Assistant Remote Controller\n", .{});
    try stdout.print("  ============================================\n\n", .{});
    try stdout.print("  Server: http://{s}:{d}\n", .{ config.bind, config.port });
    try stdout.print("  Command: {s}\n\n", .{config.command});

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/?token={s}", .{ config.bind, config.port, setup_hex });
    defer allocator.free(url);
    try auth_mod.renderQrCode(stdout, url);
    try stdout.flush();

    // Initialize session
    var session = try Session.init(allocator, 1);
    defer session.deinit();
    session.state = .running;

    // Initialize broadcaster
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    // Open PTY and spawn child
    var pty = try Pty.open();
    defer pty.close();
    global_pty = &pty;

    // Forward current terminal size to PTY before spawning
    if (terminal.getWindowSize(stdin_fd)) |ws| {
        pty.setWindowSize(ws.rows, ws.cols);
    }

    const cmd_z = try allocator.dupeZ(u8, config.command);
    defer allocator.free(cmd_z);
    const argv = [_]?[*:0]const u8{ cmd_z.ptr, null };
    try pty.spawn(&argv, null);

    const is_tty = posix.isatty(stdin_fd);

    if (is_tty) {
        // Install SIGWINCH handler to track terminal resizes
        const sa = posix.Sigaction{
            .handler = .{ .handler = &handleSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa, null);

        // Put parent terminal in raw mode so keystrokes pass through
        terminal.enableRawMode(stdin_fd) catch {};
    }
    defer if (is_tty) terminal.restoreMode(stdin_fd);

    // Start HTTP server in a separate thread
    var http_server = try HttpServer.init(
        allocator,
        config.bind,
        config.port,
        &auth,
        &broadcaster,
        &session,
        &onTerminalInput,
        &onResize,
    );
    const server_thread = try std.Thread.spawn(.{}, HttpServer.run, .{&http_server});
    _ = server_thread;

    // Start IPC listener for hooks in a separate thread
    const ipc_thread = try std.Thread.spawn(.{}, runIpcListener, .{ allocator, &broadcaster });
    _ = ipc_thread;

    // Main loop: poll stdin + PTY master concurrently
    const nfds: usize = if (is_tty) 2 else 1;
    var fds = [2]posix.pollfd{
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var stdin_buf: [4096]u8 = undefined;
    var pty_buf: [4096]u8 = undefined;

    while (pty.isChildAlive()) {
        if (is_tty and sigwinch_received.swap(false, .acquire)) {
            syncWindowSize();
        }

        const ready = posix.poll(fds[0..nfds], 100) catch break;
        if (ready == 0) continue;

        // PTY master -> stdout + WebSocket (child output)
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(pty.master, &pty_buf) catch break;
            if (n == 0) break;
            const data = pty_buf[0..n];

            session.appendTerminalOutput(data);
            _ = posix.write(stdout_fd, data) catch {};

            const msg = protocol.encodeTerminalOutput(allocator, data) catch continue;
            defer allocator.free(msg);
            broadcaster.broadcast(msg);
        }
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;

        // stdin -> PTY master (local keyboard input, only when tty)
        if (is_tty) {
            if (fds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(stdin_fd, &stdin_buf) catch break;
                if (n > 0) {
                    pty.writeMaster(stdin_buf[0..n]) catch break;
                }
            }
        }

        fds[0].revents = 0;
        fds[1].revents = 0;
    }

    // Restore terminal before printing status messages
    terminal.restoreMode(stdin_fd);

    session.state = .stopped;
    const status_msg = protocol.encodeSessionStatus(allocator, "stopped", session.id) catch return;
    defer allocator.free(status_msg);
    broadcaster.broadcast(status_msg);

    try stdout.print("\n  Session ended.\n", .{});
    try stdout.flush();
    http_server.stop();
}

fn runIpcListener(allocator: std.mem.Allocator, broadcaster: *WsBroadcaster) void {
    std.fs.deleteFileAbsolute(hooks.IPC_SOCKET_PATH) catch {};

    const server = std.net.Address.initUnix(hooks.IPC_SOCKET_PATH) catch return;
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(sock);

    posix.bind(sock, &server.any, server.getOsSockLen()) catch return;
    posix.listen(sock, 16) catch return;

    while (true) {
        const conn = posix.accept(sock, null, null, posix.SOCK.CLOEXEC) catch continue;
        handleIpcConnection(allocator, conn, broadcaster);
        posix.close(conn);
    }
}

fn handleIpcConnection(allocator: std.mem.Allocator, conn: posix.fd_t, broadcaster: *WsBroadcaster) void {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return;

    const data = buf[0..total];

    var lines = std.mem.splitScalar(u8, data, '\n');
    const event_name = lines.next() orelse return;
    _ = lines.next(); // length
    const rest = lines.rest();

    var tool_name: []const u8 = "";
    if (std.json.parseFromSlice(hooks.HookInput, allocator, rest, .{ .ignore_unknown_fields = true })) |parsed| {
        if (parsed.value.tool_name) |t| tool_name = t;
        defer parsed.deinit();
    } else |_| {}

    const msg = protocol.encodeHookEvent(allocator, event_name, tool_name, rest) catch return;
    defer allocator.free(msg);
    broadcaster.broadcast(msg);

    if (std.mem.eql(u8, event_name, "PreToolUse")) {
        _ = posix.write(conn, "{}") catch {};
    }
}

fn runHook(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var event_name: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--event") and i + 1 < args.len) {
            event_name = args[i + 1];
            i += 1;
        }
    }

    if (event_name.len == 0) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write("Usage: kite hook --event <EventName>\n") catch {};
        return;
    }

    const stdin_file = std.fs.File.stdin();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin_file.read(&read_buf) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, read_buf[0..n]);
    }

    const response = try hooks.sendHookToServer(allocator, event_name, buf.items);
    if (response) |r| {
        defer allocator.free(r);
        const stdout_file = std.fs.File.stdout();
        _ = stdout_file.write(r) catch {};
    }
}

fn runSetup(allocator: std.mem.Allocator) !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const config = try hooks.ClaudeCodeConfig.generateHooksConfig(allocator, "kite");
    defer allocator.free(config);

    try stdout.print("Add the following to your Claude Code settings\n", .{});
    try stdout.print("(~/.claude/settings.json or .claude/settings.json):\n\n", .{});
    try stdout.print("{s}\n", .{config});
    try stdout.flush();
}

fn runStatus() !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const stream = std.net.connectUnixSocket(hooks.IPC_SOCKET_PATH) catch {
        try stdout.print("kite server is not running.\n", .{});
        try stdout.flush();
        return;
    };
    stream.close();
    try stdout.print("kite server is running.\n", .{});
    try stdout.flush();
}

fn printUsage() void {
    const stdout_file = std.fs.File.stdout();
    _ = stdout_file.write(
        \\
        \\kite - AI Coding Assistant Remote Controller
        \\
        \\Usage:
        \\  kite start [options]    Start server and spawn AI assistant in PTY
        \\  kite hook --event <E>   Handle a Claude Code hook event (internal)
        \\  kite setup              Show Claude Code hooks configuration
        \\  kite status             Check if kite server is running
        \\  kite help               Show this help
        \\
        \\Options for 'start':
        \\  --port <PORT>   Server port (default: 7890)
        \\  --bind <ADDR>   Bind address (default: 0.0.0.0)
        \\  --cmd <CMD>     Command to run (default: claude)
        \\
    ) catch {};
}
