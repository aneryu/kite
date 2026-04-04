const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const Auth = @import("auth.zig").Auth;
const auth_mod = @import("auth.zig");
const HttpServer = @import("http.zig").Server;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const hooks = @import("hooks.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");
const daemon = @import("daemon.zig");
const SessionManager = @import("session_manager.zig").SessionManager;

const Config = struct {
    port: u16 = 7890,
    bind: []const u8 = "0.0.0.0",
    command: []const u8 = "claude",
};

const Command = enum {
    start,
    run,
    hook,
    setup,
    status,
    help,
};

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
        .run => try runRun(allocator, args[2..]),
        .hook => try runHook(allocator, args[2..]),
        .setup => try runSetup(allocator),
        .status => try runStatus(),
        .help => printUsage(),
    }
}

fn parseCommand(arg: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "start", .start },
        .{ "run", .run },
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
        }
    }

    if (daemon.isRunning()) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write("kite daemon is already running.\n") catch {};
        return;
    }

    try daemon.writePidFile();
    defer daemon.removePidFile();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var auth = Auth.init();
    const setup_hex = auth.getSetupTokenHex();

    try stdout.print("\n  kite daemon started\n", .{});
    try stdout.print("  ====================\n\n", .{});
    try stdout.print("  Server: http://{s}:{d}\n", .{ config.bind, config.port });

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/?token={s}", .{ config.bind, config.port, setup_hex });
    defer allocator.free(url);
    try auth_mod.renderQrCode(stdout, url);
    try stdout.print("  Use 'kite run' to create a session.\n\n", .{});
    try stdout.flush();

    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var session_manager = SessionManager.init(allocator, &broadcaster);
    defer session_manager.deinit();

    var http_server = try HttpServer.init(
        allocator,
        config.bind,
        config.port,
        &auth,
        &broadcaster,
        &session_manager,
    );
    const server_thread = try std.Thread.spawn(.{}, HttpServer.run, .{&http_server});
    _ = server_thread;

    const ipc_thread = try std.Thread.spawn(.{}, runIpcListener, .{ allocator, &broadcaster, &session_manager });
    _ = ipc_thread;

    try stdout.print("  Press Ctrl+C to stop the daemon.\n", .{});
    try stdout.flush();

    // Block until stdin closes or Ctrl+C
    var sig_buf: [1]u8 = undefined;
    _ = posix.read(posix.STDIN_FILENO, &sig_buf) catch {};

    http_server.stop();
}

fn runRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmd") and i + 1 < args.len) {
            config.command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 7890;
            i += 1;
        }
    }

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const address = try std.net.Address.parseIp("127.0.0.1", config.port);
    const stream = std.net.tcpConnectToAddress(address) catch {
        try stdout.print("Cannot connect to kite daemon. Is it running? (kite start)\n", .{});
        try stdout.flush();
        return;
    };
    defer stream.close();

    const body = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{config.command});
    defer allocator.free(body);

    const request = try std.fmt.allocPrint(allocator,
        "POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ config.port, body.len, body },
    );
    defer allocator.free(request);

    stream.writeAll(request) catch {
        try stdout.print("Failed to send request to daemon.\n", .{});
        try stdout.flush();
        return;
    };

    var response_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = stream.read(response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total > 0) {
        const response = response_buf[0..total];
        if (std.mem.indexOf(u8, response, "\r\n\r\n")) |body_start| {
            try stdout.print("  {s}\n", .{response[body_start + 4 ..]});
        } else {
            try stdout.print("  Session created.\n", .{});
        }
    } else {
        try stdout.print("  Session created.\n", .{});
    }
    try stdout.flush();
}

fn runIpcListener(allocator: std.mem.Allocator, broadcaster: *WsBroadcaster, session_manager: *SessionManager) void {
    std.fs.deleteFileAbsolute(hooks.IPC_SOCKET_PATH) catch {};

    const server = std.net.Address.initUnix(hooks.IPC_SOCKET_PATH) catch return;
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(sock);

    posix.bind(sock, &server.any, server.getOsSockLen()) catch return;
    posix.listen(sock, 16) catch return;

    while (true) {
        const conn = posix.accept(sock, null, null, posix.SOCK.CLOEXEC) catch continue;
        handleIpcConnection(allocator, conn, broadcaster, session_manager);
        posix.close(conn);
    }
}

fn handleIpcConnection(allocator: std.mem.Allocator, conn: posix.fd_t, broadcaster: *WsBroadcaster, session_manager: *SessionManager) void {
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
    var session_id: u64 = 1;
    if (std.json.parseFromSlice(hooks.HookInput, allocator, rest, .{ .ignore_unknown_fields = true })) |parsed| {
        if (parsed.value.tool_name) |t| tool_name = t;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }
        defer parsed.deinit();
    } else |_| {}

    const msg = protocol.encodeHookEvent(allocator, event_name, tool_name, rest) catch return;
    defer allocator.free(msg);
    broadcaster.broadcast(msg);

    session_manager.handleHookEvent(session_id, event_name, rest);

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
        \\  kite start [options]    Start the kite daemon
        \\  kite run [options]      Create a new session in the daemon
        \\  kite hook --event <E>   Handle a Claude Code hook event (internal)
        \\  kite setup              Show Claude Code hooks configuration
        \\  kite status             Check if kite daemon is running
        \\  kite help               Show this help
        \\
        \\Options for 'start':
        \\  --port <PORT>   Server port (default: 7890)
        \\  --bind <ADDR>   Bind address (default: 0.0.0.0)
        \\
        \\Options for 'run':
        \\  --cmd <CMD>     Command to run (default: claude)
        \\  --port <PORT>   Daemon port (default: 7890)
        \\
    ) catch {};
}
