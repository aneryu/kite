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
    attach_id: ?u64 = null,
    static_dir: ?[]const u8 = null,
    no_auth: bool = false,
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
        } else if (std.mem.eql(u8, args[i], "--static-dir") and i + 1 < args.len) {
            config.static_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-auth")) {
            config.no_auth = true;
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
    auth.disabled = config.no_auth;
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
    http_server.static_dir = config.static_dir;
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

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigwinch(_: c_int) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn runRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmd") and i + 1 < args.len) {
            config.command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--attach") and i + 1 < args.len) {
            config.attach_id = std.fmt.parseInt(u64, args[i + 1], 10) catch null;
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

    // Step 1: Create session via HTTP API (include terminal size)
    const stdin_fd = posix.STDIN_FILENO;

    var session_id: u64 = 1;

    if (config.attach_id) |aid| {
        // Attach to existing session, skip HTTP creation
        session_id = aid;
    } else {
        var term_rows: u16 = 24;
        var term_cols: u16 = 80;
        if (terminal.getWindowSize(stdin_fd)) |ws| {
            term_rows = ws.rows;
            term_cols = ws.cols;
        }

        const address = try std.net.Address.parseIp("127.0.0.1", config.port);
        const http_stream = std.net.tcpConnectToAddress(address) catch {
            try stdout.print("Cannot connect to kite daemon. Is it running? (kite start)\n", .{});
            try stdout.flush();
            return;
        };

        const body = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\",\"rows\":{d},\"cols\":{d}}}", .{ config.command, term_rows, term_cols });
        defer allocator.free(body);

        const request = try std.fmt.allocPrint(allocator,
            "POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ config.port, body.len, body },
        );
        defer allocator.free(request);

        http_stream.writeAll(request) catch {
            http_stream.close();
            try stdout.print("Failed to send request to daemon.\n", .{});
            try stdout.flush();
            return;
        };

        // Read HTTP response to get session_id
        var response_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < response_buf.len) {
            const n = http_stream.read(response_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        http_stream.close();

        if (total > 0) {
            const response = response_buf[0..total];
            if (std.mem.indexOf(u8, response, "\r\n\r\n")) |body_start| {
                const resp_body = response[body_start + 4 ..];
                const parsed = std.json.parseFromSlice(struct { session_id: u64 = 0 }, allocator, resp_body, .{
                    .ignore_unknown_fields = true,
                }) catch null;
                if (parsed) |p| {
                    session_id = p.value.session_id;
                    p.deinit();
                }
            }
        }
    }

    // Step 2: Attach to session via IPC Unix socket
    const ipc_stream = std.net.connectUnixSocket(hooks.IPC_SOCKET_PATH) catch {
        try stdout.print("Cannot connect to daemon IPC socket.\n", .{});
        try stdout.flush();
        return;
    };
    defer ipc_stream.close();
    const ipc_fd = ipc_stream.handle;

    // Send attach command
    const attach_cmd = try std.fmt.allocPrint(allocator, "attach\n{d}\n", .{session_id});
    defer allocator.free(attach_cmd);
    ipc_stream.writeAll(attach_cmd) catch {
        try stdout.print("Failed to attach to session.\n", .{});
        try stdout.flush();
        return;
    };

    // Wait for "ok" response
    var ack_buf: [16]u8 = undefined;
    const ack_n = ipc_stream.read(&ack_buf) catch 0;
    if (ack_n < 2 or !std.mem.startsWith(u8, ack_buf[0..ack_n], "ok")) {
        try stdout.print("Failed to attach to session.\n", .{});
        try stdout.flush();
        return;
    }

    // Step 3: Enter raw terminal mode and relay I/O
    const stdout_fd = posix.STDOUT_FILENO;
    const is_tty = posix.isatty(stdin_fd);

    if (is_tty) {
        // Sync terminal size to PTY via IPC
        if (terminal.getWindowSize(stdin_fd)) |ws| {
            const resize_cmd = std.fmt.allocPrint(allocator, "resize\n{d}\n{d}\n", .{ ws.rows, ws.cols }) catch null;
            if (resize_cmd) |cmd| {
                defer allocator.free(cmd);
                ipc_stream.writeAll(cmd) catch {};
            }
        }

        // Install SIGWINCH handler
        const sa = posix.Sigaction{
            .handler = .{ .handler = &handleSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa, null);

        terminal.enableRawMode(stdin_fd) catch {};
    }
    defer if (is_tty) terminal.restoreMode(stdin_fd);

    // Main relay loop: poll IPC socket + stdin
    const nfds: usize = if (is_tty) 2 else 1;
    var fds = [2]posix.pollfd{
        .{ .fd = ipc_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var stdin_buf: [4096]u8 = undefined;
    var ipc_buf: [4096]u8 = undefined;

    while (true) {
        if (is_tty and sigwinch_received.swap(false, .acquire)) {
            if (terminal.getWindowSize(stdin_fd)) |ws| {
                const resize_cmd = std.fmt.allocPrint(allocator, "resize\n{d}\n{d}\n", .{ ws.rows, ws.cols }) catch null;
                if (resize_cmd) |cmd| {
                    defer allocator.free(cmd);
                    ipc_stream.writeAll(cmd) catch {};
                }
            }
        }

        const ready = posix.poll(fds[0..nfds], 100) catch break;
        if (ready == 0) continue;

        // IPC socket → stdout (PTY output from daemon)
        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(ipc_fd, &ipc_buf) catch break;
            if (n == 0) break; // daemon closed connection / session ended
            _ = posix.write(stdout_fd, ipc_buf[0..n]) catch {};
        }
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;

        // stdin → IPC socket (keyboard input to daemon → PTY)
        if (is_tty) {
            if (fds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(stdin_fd, &stdin_buf) catch break;
                if (n > 0) {
                    ipc_stream.writeAll(stdin_buf[0..n]) catch break;
                }
            }
        }

        fds[0].revents = 0;
        fds[1].revents = 0;
    }

    // Restore terminal before printing
    if (is_tty) terminal.restoreMode(stdin_fd);

    try stdout.print("\n  Session ended.\n", .{});
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
        // handleIpcConnection returns true if it's a long-lived attach connection
        // (already handled, don't close). Returns false for normal hook events.
        const is_attach = handleIpcConnection(allocator, conn, broadcaster, session_manager);
        if (!is_attach) {
            posix.close(conn);
        }
    }
}

/// Returns true if this is an attach connection (long-lived, caller should NOT close).
fn handleIpcConnection(allocator: std.mem.Allocator, conn: posix.fd_t, broadcaster: *WsBroadcaster, session_manager: *SessionManager) bool {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;

    // Read initial data (with short timeout for attach detection)
    while (total < buf.len) {
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        // For hook events, data comes in one shot. Check if we have enough.
        break;
    }

    if (total == 0) return false;

    const data = buf[0..total];

    var lines = std.mem.splitScalar(u8, data, '\n');
    const event_name = lines.next() orelse return false;

    // Handle "attach" command — long-lived terminal relay connection
    if (std.mem.eql(u8, event_name, "attach")) {
        const sid_str = lines.next() orelse return false;
        const session_id = std.fmt.parseInt(u64, std.mem.trim(u8, sid_str, " \r"), 10) catch 1;

        // Verify session exists before attaching
        if (session_manager.getSession(session_id) == null) {
            _ = posix.write(conn, "error\n") catch {};
            return false;
        }

        // Send "ok" BEFORE attachLocal to avoid race condition:
        // If we attachLocal first, ioRelay may write PTY output to conn
        // before "ok\n" is sent, causing the client handshake to fail.
        _ = posix.write(conn, "ok\n") catch {};

        // Now attach — ioRelay will start writing PTY output to this fd
        if (!session_manager.attachLocal(session_id, conn)) {
            return false;
        }

        // Send buffered terminal history so client sees current state
        if (session_manager.getSession(session_id)) |session| {
            const history = session.terminal_buffer.slice();
            if (history.first.len > 0) {
                _ = posix.write(conn, history.first) catch {};
            }
            if (history.second.len > 0) {
                _ = posix.write(conn, history.second) catch {};
            }
        }

        // Spawn a thread for the attach relay so IPC listener isn't blocked
        const attach_thread = std.Thread.spawn(.{}, handleAttachThread, .{ session_manager, session_id, conn }) catch {
            session_manager.detachLocal(session_id);
            posix.close(conn);
            return true;
        };
        attach_thread.detach();
        return true; // Caller should NOT close conn; the thread owns it now
    }

    // Normal hook event handling
    _ = lines.next(); // length
    const rest = lines.rest();

    // May need more data for large payloads
    while (total < buf.len) {
        var poll_fds = [1]posix.pollfd{
            .{ .fd = conn, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&poll_fds, 10) catch break;
        if (ready == 0) break;
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    var tool_name: []const u8 = "";
    var session_id: u64 = 1;
    if (std.json.parseFromSlice(hooks.HookInput, allocator, rest, .{ .ignore_unknown_fields = true })) |parsed| {
        if (parsed.value.tool_name) |t| tool_name = t;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }
        defer parsed.deinit();
    } else |_| {}

    const msg = protocol.encodeHookEvent(allocator, event_name, tool_name, rest, session_id) catch return false;
    defer allocator.free(msg);
    broadcaster.broadcast(msg);

    session_manager.handleHookEvent(session_id, event_name, rest);

    if (std.mem.eql(u8, event_name, "PreToolUse")) {
        _ = posix.write(conn, "{}") catch {};
    }

    return false;
}

/// Thread wrapper for attach handling — owns the connection lifetime.
fn handleAttachThread(session_manager: *SessionManager, session_id: u64, conn: posix.fd_t) void {
    handleAttachedSession(session_manager, session_id, conn);
    session_manager.detachLocal(session_id);
    posix.close(conn);
}

/// Handle a locally attached terminal session.
/// Reads input from the local terminal (via IPC conn) and writes to PTY.
/// Runs until the connection closes or session ends.
fn handleAttachedSession(session_manager: *SessionManager, session_id: u64, conn: posix.fd_t) void {
    var buf: [4096]u8 = undefined;

    while (true) {
        var fds = [1]posix.pollfd{
            .{ .fd = conn, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, 200) catch break;

        // Check if session is still alive
        if (session_manager.getSession(session_id)) |session| {
            if (session.state == .stopped) break;
        } else break;

        if (ready == 0) continue;

        if (fds[0].revents & posix.POLL.IN != 0) {
            const n = posix.read(conn, &buf) catch break;
            if (n == 0) break;
            const data = buf[0..n];

            // Check for inline "resize" command from the client
            if (std.mem.startsWith(u8, data, "resize\n")) {
                var resize_lines = std.mem.splitScalar(u8, data, '\n');
                _ = resize_lines.next(); // "resize"
                const rows_str = resize_lines.next() orelse continue;
                const cols_str = resize_lines.next() orelse continue;
                const rows = std.fmt.parseInt(u16, std.mem.trim(u8, rows_str, " \r"), 10) catch continue;
                const cols = std.fmt.parseInt(u16, std.mem.trim(u8, cols_str, " \r"), 10) catch continue;
                session_manager.resizeSession(session_id, rows, cols);
                continue;
            }

            // Normal terminal input → PTY
            session_manager.writeToSession(session_id, data) catch break;
        }
        if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
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
        \\  --port <PORT>          Server port (default: 7890)
        \\  --bind <ADDR>          Bind address (default: 0.0.0.0)
        \\  --static-dir <DIR>     Serve static files from directory
        \\  --no-auth              Disable authentication (development only)
        \\
        \\Options for 'run':
        \\  --cmd <CMD>       Command to run (default: claude)
        \\  --attach <ID>     Attach to existing session instead of creating new one
        \\  --port <PORT>     Daemon port (default: 7890)
        \\
    ) catch {};
}
