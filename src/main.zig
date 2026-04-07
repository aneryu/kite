const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const session_mod = @import("session.zig");
const Auth = @import("auth.zig").Auth;
const auth_mod = @import("auth.zig");
const hooks = @import("hooks.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");
const daemon = @import("daemon.zig");
const SessionManager = @import("session_manager.zig").SessionManager;
const SessionInfo = @import("session_manager.zig").SessionInfo;
const MessageQueue = @import("message_queue.zig").MessageQueue;
const SignalClient = @import("signal_client.zig").SignalClient;
const RtcPeer = @import("rtc.zig").RtcPeer;
const rtc_mod = @import("rtc.zig");

const Config = struct {
    command: []const u8 = "claude",
    attach_id: ?u64 = null,
    no_auth: bool = false,
    signal_url: []const u8 = "wss://relay.fun.dev/ws",
    turn_server: ?[]const u8 = null,
    extra_ice: [8]?[]const u8 = [_]?[]const u8{null} ** 8,
    extra_ice_count: usize = 0,
    ws_port: u16 = 7891,
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
    log.init();
    defer log.deinit();
    cli.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        cli.printRootHelp();
        return;
    }

    const cmd = parseCommand(args[1]) orelse {
        cli.printUnknownCommand(args[1]);
        return;
    };

    switch (cmd) {
        .start => try runStart(allocator, args[2..]),
        .run => try runRun(allocator, args[2..]),
        .hook => try runHook(allocator, args[2..]),
        .setup => try runSetup(allocator, args[2..]),
        .status => try runStatus(allocator, args[2..]),
        .help => cli.printRootHelp(),
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

const FileConfig = struct {
    signal_url: []const u8 = "wss://relay.fun.dev/ws",
    pairing_code: []const u8 = "",
    setup_secret: []const u8 = "",
};

fn readConfigFile(allocator: std.mem.Allocator) ?FileConfig {
    const home = std.posix.getenv("HOME") orelse return null;
    const config_path = std.fmt.allocPrint(allocator, "{s}/.config/kite/config.json", .{home}) catch return null;
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(FileConfig, allocator, contents, .{ .ignore_unknown_fields = true }) catch return null;
    const url = allocator.dupe(u8, parsed.value.signal_url) catch return null;
    const code = allocator.dupe(u8, parsed.value.pairing_code) catch return null;
    const secret = allocator.dupe(u8, parsed.value.setup_secret) catch return null;
    parsed.deinit();
    return FileConfig{ .signal_url = url, .pairing_code = code, .setup_secret = secret };
}

fn writeConfigFile(allocator: std.mem.Allocator, config: FileConfig) void {
    const home = std.posix.getenv("HOME") orelse return;
    const config_dir = std.fmt.allocPrint(allocator, "{s}/.config/kite", .{home}) catch return;
    defer allocator.free(config_dir);
    const parent_dir = std.fmt.allocPrint(allocator, "{s}/.config", .{home}) catch return;
    defer allocator.free(parent_dir);
    std.fs.makeDirAbsolute(parent_dir) catch {};
    std.fs.makeDirAbsolute(config_dir) catch {};

    const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir}) catch return;
    defer allocator.free(config_path);

    const escaped_url = protocol.jsonEscapeAllocPublic(allocator, config.signal_url) catch return;
    defer allocator.free(escaped_url);
    const config_json = std.fmt.allocPrint(allocator, "{{\"signal_url\":\"{s}\",\"pairing_code\":\"{s}\",\"setup_secret\":\"{s}\"}}\n", .{ escaped_url, config.pairing_code, config.setup_secret }) catch return;
    defer allocator.free(config_json);

    const file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer file.close();
    file.writeAll(config_json) catch {};
}

// Module-level mutable state for peer connections
var global_peers: std.StringHashMap(*RtcPeer) = undefined;
var global_peers_allocator: std.mem.Allocator = undefined;
var global_data_queue: *MessageQueue = undefined;
var global_state_queue: *MessageQueue = undefined;
var global_ws_server: ?*@import("ws_server.zig").WsServer = null;
var global_ice_servers: []const []const u8 = &rtc_mod.default_ice_servers;

fn initGlobalPeers(allocator: std.mem.Allocator, data_queue: *MessageQueue, state_queue: *MessageQueue) void {
    global_peers = std.StringHashMap(*RtcPeer).init(allocator);
    global_peers_allocator = allocator;
    global_data_queue = data_queue;
    global_state_queue = state_queue;
}

fn broadcastViaRtc(data: []const u8) void {
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.send(data) catch {};
    }
    if (global_ws_server) |ws| {
        ws.broadcast(data);
    }
}

fn markAllPeersAuthenticated() void {
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.authenticated = true;
    }
    if (global_ws_server) |ws| {
        ws.markAllAuthenticated();
    }
}

/// Send terminal output in chunks to avoid exceeding WebRTC DataChannel message size limit (256KB).
/// Raw data is split into 128KB chunks, each base64-encoded and sent as a separate terminal_output message.
const snapshot_chunk_size = 128 * 1024;

fn broadcastTerminalSnapshot(allocator: std.mem.Allocator, data: []const u8, session_id: u64) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + snapshot_chunk_size, data.len);
        const chunk = data[offset..end];
        const encoded = protocol.encodeTerminalOutput(allocator, chunk, session_id) catch return;
        defer allocator.free(encoded);
        broadcastViaRtc(encoded);
        offset = end;
    }
}

fn runStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    // Read config file defaults
    var file_config = readConfigFile(allocator) orelse FileConfig{};
    config.signal_url = file_config.signal_url;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            cli.printStartHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--no-auth")) {
            config.no_auth = true;
        } else if (std.mem.eql(u8, args[i], "--signal-url")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--signal-url <URL>", "start", "kite start --signal-url <URL>");
                return;
            }
            config.signal_url = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--ws-port")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--ws-port <PORT>", "start", "kite start --ws-port <PORT>");
                return;
            }
            config.ws_port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                cli.printMissingOption("--ws-port <PORT>", "start", "kite start --ws-port <PORT>");
                return;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--ice-server")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--ice-server <URL>", "start", "kite start --ice-server <URL>");
                return;
            }
            if (config.extra_ice_count < config.extra_ice.len) {
                config.extra_ice[config.extra_ice_count] = args[i + 1];
                config.extra_ice_count += 1;
            }
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const start_opts = [_][]const u8{ "--no-auth", "--signal-url", "--ws-port", "--ice-server" };
            cli.printUnknownOption(args[i], &start_opts, "start");
            return;
        }
    }

    if (daemon.isRunning()) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write("kite daemon is already running.\n") catch {};
        if (file_config.signal_url.len > 0) allocator.free(file_config.signal_url);
        if (file_config.pairing_code.len > 0) allocator.free(file_config.pairing_code);
        if (file_config.setup_secret.len > 0) allocator.free(file_config.setup_secret);
        return;
    }

    try daemon.writePidFile();
    defer daemon.removePidFile();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Generate or load persistent pairing code and setup secret
    var pairing_code: [6]u8 = undefined;
    var setup_secret_hex: [64]u8 = undefined;

    if (file_config.pairing_code.len == 6 and file_config.setup_secret.len == 64) {
        @memcpy(&pairing_code, file_config.pairing_code[0..6]);
        @memcpy(&setup_secret_hex, file_config.setup_secret[0..64]);
    } else {
        pairing_code = auth_mod.generatePairingCode();
        var secret_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);
        setup_secret_hex = std.fmt.bytesToHex(secret_bytes, .lower);
        // Save to config
        file_config.pairing_code = &pairing_code;
        file_config.setup_secret = &setup_secret_hex;
        file_config.signal_url = config.signal_url;
        writeConfigFile(allocator, file_config);
    }

    var auth = Auth.init();
    auth.disabled = config.no_auth;
    auth.setSetupSecret(&setup_secret_hex);

    const signal_host, const signal_port = parseSignalUrl(config.signal_url);

    try stdout.print("\n", .{});

    if (config.no_auth) {
        try stdout.print("  kite daemon started (auth disabled)\n\n", .{});
    } else {
        const pairing_url = try std.fmt.allocPrint(allocator, "https://kite.fun.dev/remote/#/pair/{s}:{s}", .{ pairing_code, setup_secret_hex });
        defer allocator.free(pairing_url);

        const qr_mod = @import("qr.zig");
        if (qr_mod.encode(pairing_url)) |qr_result| {
            try qr_mod.renderTerminal(stdout, qr_result, "  ");
            try stdout.print("\n", .{});
        } else |_| {}

        try stdout.print("  {s}\n\n", .{pairing_url});
    }
    try stdout.flush();

    // Create message queues
    var data_queue = MessageQueue.init(allocator);
    defer data_queue.deinit();
    var signal_queue = MessageQueue.init(allocator);
    defer signal_queue.deinit();
    var state_queue = MessageQueue.init(allocator);
    defer state_queue.deinit();

    initGlobalPeers(allocator, &data_queue, &state_queue);

    // WS server for LAN connections
    const net_info = @import("net_info.zig");
    const WsServer = @import("ws_server.zig").WsServer;
    var ws_queue = MessageQueue.init(allocator);
    defer ws_queue.deinit();

    var lan_ip_buf: [16]u8 = undefined;
    const lan_ip = net_info.getLanIp(&lan_ip_buf);

    var ws_server: ?WsServer = WsServer.init(allocator, config.ws_port, &ws_queue) catch |err| blk: {
        logStderr("[kite] WS server failed to bind port {d}: {}", .{ config.ws_port, err });
        break :blk null;
    };
    defer if (ws_server) |*ws| ws.deinit();

    if (ws_server != null) {
        if (lan_ip) |ip| {
            try stdout.print("  LAN: ws://{s}:{d}\n", .{ ip, config.ws_port });
        } else {
            try stdout.print("  LAN: ws://localhost:{d}\n", .{config.ws_port});
        }
        try stdout.flush();
    }

    var session_manager = SessionManager.init(allocator, &broadcastViaRtc);
    defer session_manager.deinit();

    // Connect to signal server
    var signal_client = SignalClient.connect(allocator, signal_host, signal_port, "/ws", &signal_queue, &pairing_code) catch |err| {
        logStderr("[kite] Failed to connect to signal server {s}:{d}: {}", .{ signal_host, signal_port, err });
        printStatus("  Signal server connection failed\n");
        return;
    };
    defer signal_client.deinit();
    signal_client.lan_ip = lan_ip;
    signal_client.lan_port = config.ws_port;
    const ice_servers = buildIceServerList(allocator, config) catch null;
    defer if (ice_servers) |s| allocator.free(s);
    global_ice_servers = ice_servers orelse &rtc_mod.default_ice_servers;
    const ice_json = buildIceServersJson(allocator, global_ice_servers) catch null;
    defer if (ice_json) |j| allocator.free(j);
    signal_client.ice_servers_json = ice_json;
    signal_client.joinTopic() catch |err| {
        logStderr("[kite] Failed to join signal topic: {}", .{err});
        printStatus("  Failed to join signal topic\n");
        return;
    };

    logStderr("[kite] Connected to signal server {s}:{d}", .{ signal_host, signal_port });
    printStatus("  Signal server connected\n");

    // Spawn signal read loop thread
    const signal_thread = std.Thread.spawn(.{}, SignalClient.readLoop, .{&signal_client}) catch |err| {
        logStderr("[kite] Failed to spawn signal read loop: {}", .{err});
        return;
    };
    signal_thread.detach();

    // Spawn WS server thread for LAN connections
    if (ws_server) |*ws| {
        global_ws_server = ws;
        _ = std.Thread.spawn(.{}, WsServer.run, .{ws}) catch |err| {
            logStderr("[kite] Failed to spawn WS server thread: {}", .{err});
        };
    }

    // Spawn IPC listener thread (unchanged)
    const ipc_thread = try std.Thread.spawn(.{}, runIpcListener, .{ allocator, &session_manager });
    _ = ipc_thread;

    try stdout.print("  Press Ctrl+C to stop the daemon.\n", .{});
    try stdout.flush();

    // Initialize libdatachannel logger
    rtc_mod.initLogger(2); // RTC_LOG_ERROR

    // Main event loop — poll all queues
    while (true) {
        // Check stdin for EOF (daemon termination)
        var stdin_fds = [1]posix.pollfd{
            .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
        };
        const stdin_ready = posix.poll(&stdin_fds, 0) catch break;
        if (stdin_ready > 0) {
            if (stdin_fds[0].revents & posix.POLL.IN != 0 or
                stdin_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0)
            {
                var sig_buf: [1]u8 = undefined;
                const n = posix.read(posix.STDIN_FILENO, &sig_buf) catch break;
                if (n == 0) break; // EOF — stdin closed
            }
        }

        // Process signal queue messages
        const signal_msgs = signal_queue.drain() catch break;
        if (signal_msgs.len > 0) {
            logStderr("[kite-loop] signal_queue: {d} messages", .{signal_msgs.len});
            defer signal_queue.freeBatch(signal_msgs);
            for (signal_msgs) |msg| {
                logStderr("[kite-loop] signal msg: {s}", .{msg[0..@min(msg.len, 200)]});
                handleSignalMessage(allocator, msg, &session_manager, &auth, &data_queue, &state_queue, config);
            }
        }

        // Process RTC state changes
        const state_msgs = state_queue.drain() catch break;
        if (state_msgs.len > 0) {
            logStderr("[kite-loop] state_queue: {d} messages", .{state_msgs.len});
            defer state_queue.freeBatch(state_msgs);
            for (state_msgs) |msg| {
                logStderr("[kite-loop] state msg: {s}", .{msg[0..@min(msg.len, 200)]});
                handleRtcStateMessage(allocator, msg, &signal_client, &session_manager, &auth);
            }
        }

        // Process DataChannel messages from browser
        const data_msgs = data_queue.drain() catch break;
        if (data_msgs.len > 0) {
            logStderr("[kite-loop] data_queue: {d} messages", .{data_msgs.len});
            defer data_queue.freeBatch(data_msgs);
            for (data_msgs) |msg| {
                logStderr("[kite-loop] data msg: {s}", .{msg[0..@min(msg.len, 200)]});
                handleDataChannelMessage(allocator, msg, &session_manager, &auth);
            }
        }

        // Process WS server messages from LAN clients
        const ws_msgs = ws_queue.drain() catch break;
        if (ws_msgs.len > 0) {
            logStderr("[kite-loop] ws_queue: {d} messages", .{ws_msgs.len});
            defer ws_queue.freeBatch(ws_msgs);
            for (ws_msgs) |msg| {
                logStderr("[kite-loop] ws msg: {s}", .{msg[0..@min(msg.len, 200)]});
                handleDataChannelMessage(allocator, msg, &session_manager, &auth);
            }
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    // Cleanup all peers
    var cleanup_it = global_peers.iterator();
    while (cleanup_it.next()) |entry| {
        entry.value_ptr.*.deinit();
        allocator.destroy(entry.value_ptr.*);
        allocator.free(entry.key_ptr.*);
    }
    global_peers.deinit();
    rtc_mod.cleanup();
}

fn buildIceServerList(allocator: std.mem.Allocator, config: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    // User-defined servers first (TURN, custom STUN) — tried before defaults
    for (config.extra_ice[0..config.extra_ice_count]) |maybe| {
        if (maybe) |srv| {
            try list.append(allocator, srv);
        }
    }
    if (config.turn_server) |turn| {
        try list.append(allocator, turn);
    }
    // Built-in STUN servers as fallback
    for (rtc_mod.default_ice_servers) |srv| {
        try list.append(allocator, srv);
    }
    return list.toOwnedSlice(allocator);
}

fn buildIceServersJson(allocator: std.mem.Allocator, ice_servers: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[");

    for (ice_servers, 0..) |srv, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, srv);
        try buf.appendSlice(allocator, "\"");
    }

    try buf.appendSlice(allocator, "]");
    return try allocator.dupe(u8, buf.items);
}

/// Parse ws://host:port or wss://host:port into (host, port).
fn parseSignalUrl(url: []const u8) struct { []const u8, u16 } {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "ws://")) {
        rest = rest[5..];
    } else if (std.mem.startsWith(u8, rest, "wss://")) {
        rest = rest[6..];
    }
    // Strip path if present
    if (std.mem.indexOf(u8, rest, "/")) |slash| {
        rest = rest[0..slash];
    }
    // Split host:port
    if (std.mem.lastIndexOf(u8, rest, ":")) |colon| {
        const host = rest[0..colon];
        const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch 8080;
        return .{ host, port };
    }
    return .{ rest, 8080 };
}

fn handleSignalMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    session_manager: *SessionManager,
    auth: *Auth,
    data_queue: *MessageQueue,
    state_queue: *MessageQueue,
    config: Config,
) void {
    _ = auth;
    const parsed = std.json.parseFromSlice(struct {
        type: []const u8,
        member_id: ?[]const u8 = null,
        role: ?[]const u8 = null,
        from: ?[]const u8 = null,
    }, allocator, raw, .{ .ignore_unknown_fields = true }) catch {
        logStderr("[kite-signal] Failed to parse signal message", .{});
        return;
    };
    defer parsed.deinit();
    const msg = parsed.value;

    if (std.mem.eql(u8, msg.type, "joined")) {
        logStderr("[kite-signal] Joined topic, creating peers for existing browsers", .{});
        createPeersForExistingMembers(allocator, raw, data_queue, state_queue, config);
        _ = session_manager;
    } else if (std.mem.eql(u8, msg.type, "member_joined")) {
        const role = msg.role orelse "";
        const member_id = msg.member_id orelse return;
        if (std.mem.eql(u8, role, "browser")) {
            logStderr("[kite-signal] Browser joined: {s}", .{member_id});
            createPeerForMember(allocator, member_id, data_queue, state_queue, config);
        }
    } else if (std.mem.eql(u8, msg.type, "member_left")) {
        const member_id = msg.member_id orelse return;
        logStderr("[kite-signal] Member left: {s}", .{member_id});
        destroyPeer(allocator, member_id);
    } else if (std.mem.eql(u8, msg.type, "relay")) {
        const from = msg.from orelse return;
        handleRelayPayload(allocator, from, raw);
    }
}

fn createPeersForExistingMembers(
    allocator: std.mem.Allocator,
    raw: []const u8,
    data_queue: *MessageQueue,
    state_queue: *MessageQueue,
    config: Config,
) void {
    // Parse the "members" array from the joined message
    const MemberInfo = struct {
        id: []const u8,
        role: []const u8,
    };
    const JoinedMsg = struct {
        members: []const MemberInfo = &.{},
    };
    const parsed = std.json.parseFromSlice(JoinedMsg, allocator, raw, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    for (parsed.value.members) |member| {
        if (std.mem.eql(u8, member.role, "browser")) {
            logStderr("[kite-signal] Creating peer for existing browser: {s}", .{member.id});
            createPeerForMember(allocator, member.id, data_queue, state_queue, config);
        }
    }
}

fn createPeerForMember(
    allocator: std.mem.Allocator,
    member_id: []const u8,
    data_queue: *MessageQueue,
    state_queue: *MessageQueue,
    config: Config,
) void {
    _ = config;
    // If peer already exists for this member, clean it up first
    if (global_peers.fetchRemove(member_id)) |old_entry| {
        old_entry.value.deinit();
        allocator.destroy(old_entry.value);
        allocator.free(old_entry.key);
    }

    const key = allocator.dupe(u8, member_id) catch return;
    const peer = allocator.create(RtcPeer) catch {
        allocator.free(key);
        return;
    };
    peer.* = RtcPeer.init(allocator, data_queue, state_queue, key);
    peer.setupPeerConnection(.{
        .ice_servers = global_ice_servers,
    }) catch {
        peer.deinit();
        allocator.destroy(peer);
        allocator.free(key);
        return;
    };
    global_peers.put(key, peer) catch {
        peer.deinit();
        allocator.destroy(peer);
        allocator.free(key);
    };
}

fn destroyPeer(allocator: std.mem.Allocator, member_id: []const u8) void {
    if (global_peers.fetchRemove(member_id)) |entry| {
        entry.value.deinit();
        allocator.destroy(entry.value);
        allocator.free(entry.key);
    }
}

fn rebuildPeerForRestart(allocator: std.mem.Allocator, member_id: []const u8, was_authenticated: bool, sdp: []const u8, sdp_type: []const u8) void {
    // Remove old peer
    const old_entry = global_peers.fetchRemove(member_id) orelse return;
    old_entry.value.deinit();
    allocator.destroy(old_entry.value);

    // Create new peer reusing the same key
    const peer = allocator.create(RtcPeer) catch {
        allocator.free(old_entry.key);
        return;
    };
    peer.* = RtcPeer.init(allocator, global_data_queue, global_state_queue, old_entry.key);
    peer.authenticated = was_authenticated;
    peer.setupPeerConnection(.{
        .ice_servers = global_ice_servers,
    }) catch {
        peer.deinit();
        allocator.destroy(peer);
        allocator.free(old_entry.key);
        return;
    };
    global_peers.put(old_entry.key, peer) catch {
        peer.deinit();
        allocator.destroy(peer);
        allocator.free(old_entry.key);
        return;
    };

    // Apply the SDP offer on the fresh peer
    peer.setRemoteDescription(sdp, sdp_type) catch |err| {
        logStderr("[kite-signal] Rebuilt peer still failed setRemoteDescription: {}", .{err});
    };
}

fn handleRelayPayload(allocator: std.mem.Allocator, from: []const u8, raw: []const u8) void {
    // Parse the payload object from the relay message
    const RelayMsg = struct {
        payload: struct {
            type: []const u8 = "",
            sdp: ?[]const u8 = null,
            sdp_type: ?[]const u8 = null,
            candidate: ?[]const u8 = null,
            mid: ?[]const u8 = null,
        } = .{},
    };
    const parsed = std.json.parseFromSlice(RelayMsg, allocator, raw, .{ .ignore_unknown_fields = true }) catch {
        logStderr("[kite-signal] Failed to parse relay payload", .{});
        return;
    };
    defer parsed.deinit();
    const payload = parsed.value.payload;

    const peer = global_peers.get(from) orelse {
        logStderr("[kite-signal] No peer for relay from: {s}", .{from});
        return;
    };

    if (std.mem.eql(u8, payload.type, "sdp_offer")) {
        logStderr("[kite-signal] Received SDP offer from {s} (len={d})", .{ from, (payload.sdp orelse "").len });
        // libdatachannel does not support ICE restart on an existing PeerConnection.
        // Rebuild the peer but preserve the authenticated flag so the user doesn't
        // need to re-authenticate after a reconnect.
        const was_auth = peer.authenticated;
        peer.setRemoteDescription(payload.sdp orelse return, payload.sdp_type orelse "offer") catch |err| {
            logStderr("[kite-signal] setRemoteDescription failed ({}) — rebuilding peer for ICE restart", .{err});
            rebuildPeerForRestart(allocator, from, was_auth, payload.sdp orelse return, payload.sdp_type orelse "offer");
            return;
        };
    } else if (std.mem.eql(u8, payload.type, "ice_candidate")) {
        logStderr("[kite-signal] Received ICE candidate from {s}", .{from});
        peer.addRemoteCandidate(payload.candidate orelse return, payload.mid orelse "") catch |err| {
            logStderr("[kite-signal] Failed to add remote candidate: {}", .{err});
        };
    }
}

fn handleRtcStateMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    signal_client: *SignalClient,
    session_manager: *SessionManager,
    auth: *Auth,
) void {
    const parsed = std.json.parseFromSlice(struct {
        type: []const u8,
        member_id: ?[]const u8 = null,
        sdp: ?[]const u8 = null,
        sdp_type: ?[]const u8 = null,
        candidate: ?[]const u8 = null,
        mid: ?[]const u8 = null,
        state: ?[]const u8 = null,
    }, allocator, raw, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const msg = parsed.value;

    if (std.mem.eql(u8, msg.type, "local_description")) {
        const member_id = msg.member_id orelse return;
        logStderr("[kite-rtc] Got local_description for {s}, forwarding as sdp_answer (sdp len={d}, type={s})", .{ member_id, (msg.sdp orelse "").len, msg.sdp_type orelse "answer" });
        const escaped_sdp = protocol.jsonEscapeAllocPublic(allocator, msg.sdp orelse return) catch return;
        defer allocator.free(escaped_sdp);
        const escaped_type = protocol.jsonEscapeAllocPublic(allocator, msg.sdp_type orelse "answer") catch return;
        defer allocator.free(escaped_type);
        const escaped_to = protocol.jsonEscapeAllocPublic(allocator, member_id) catch return;
        defer allocator.free(escaped_to);
        const json = std.fmt.allocPrint(allocator, "{{\"type\":\"relay\",\"to\":\"{s}\",\"payload\":{{\"type\":\"sdp_answer\",\"sdp\":\"{s}\",\"sdp_type\":\"{s}\"}}}}", .{
            escaped_to,
            escaped_sdp,
            escaped_type,
        }) catch return;
        defer allocator.free(json);
        signal_client.sendJson(json) catch |err| {
            logStderr("[kite-rtc] Failed to send sdp_answer relay: {}", .{err});
        };
        logStderr("[kite-rtc] sdp_answer relayed to {s}", .{member_id});
    } else if (std.mem.eql(u8, msg.type, "local_candidate")) {
        const member_id = msg.member_id orelse return;
        logStderr("[kite-rtc] Got local_candidate for {s}, forwarding via signal", .{member_id});
        const escaped_cand = protocol.jsonEscapeAllocPublic(allocator, msg.candidate orelse return) catch return;
        defer allocator.free(escaped_cand);
        const escaped_mid = protocol.jsonEscapeAllocPublic(allocator, msg.mid orelse "") catch return;
        defer allocator.free(escaped_mid);
        const escaped_to = protocol.jsonEscapeAllocPublic(allocator, member_id) catch return;
        defer allocator.free(escaped_to);
        const json = std.fmt.allocPrint(allocator, "{{\"type\":\"relay\",\"to\":\"{s}\",\"payload\":{{\"type\":\"ice_candidate\",\"candidate\":\"{s}\",\"mid\":\"{s}\"}}}}", .{
            escaped_to,
            escaped_cand,
            escaped_mid,
        }) catch return;
        defer allocator.free(json);
        signal_client.sendJson(json) catch |err| {
            logStderr("[kite-rtc] Failed to send ice_candidate relay: {}", .{err});
        };
    } else if (std.mem.eql(u8, msg.type, "state_change")) {
        const state = msg.state orelse "unknown";
        logStderr("[kite-rtc] State change ({s}): {s}", .{ msg.member_id orelse "unknown", state });
        // Print user-visible connection status
        if (std.mem.eql(u8, state, "connected")) {
            printStatus("  WebRTC connected\n");
        } else if (std.mem.eql(u8, state, "failed")) {
            printStatus("  WebRTC connection failed\n");
        } else if (std.mem.eql(u8, state, "disconnected")) {
            printStatus("  WebRTC disconnected\n");
        }
    } else if (std.mem.eql(u8, msg.type, "dc_open")) {
        logStderr("[kite-rtc] DataChannel opened for {s}!", .{msg.member_id orelse "unknown"});
        printStatus("  Browser connected\n");
        // If peer was previously authenticated (ICE restart), auto-sync
        if (msg.member_id) |mid| {
            if (global_peers.get(mid)) |peer| {
                if (peer.authenticated) {
                    logStderr("[kite-rtc] Peer {s} already authenticated, auto-syncing", .{mid});
                    sendSessionsSync(allocator, session_manager, auth);
                    sendTerminalSnapshots(allocator, session_manager);
                }
            }
        }
    }
}

fn sendSessionsSync(allocator: std.mem.Allocator, session_manager: *SessionManager, auth: *Auth) void {
    _ = auth;
    const sessions = session_manager.listSessions(allocator) catch return;
    defer SessionManager.freeSessionList(allocator, sessions);

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);
    json_buf.appendSlice(allocator, "{\"type\":\"sessions_sync\",\"sessions\":[") catch return;
    for (sessions, 0..) |s, idx| {
        if (idx > 0) json_buf.appendSlice(allocator, ",") catch return;
        appendSessionJson(allocator, &json_buf, s) catch return;
    }
    json_buf.appendSlice(allocator, "]}") catch return;

    broadcastViaRtc(json_buf.items);
}

fn sendTerminalSnapshots(allocator: std.mem.Allocator, session_manager: *SessionManager) void {
    const sessions = session_manager.listSessions(allocator) catch return;
    defer SessionManager.freeSessionList(allocator, sessions);

    for (sessions) |s| {
        if (session_manager.getTerminalSnapshot(allocator, s.id)) |history| {
            defer allocator.free(history);
            if (history.len > 0) {
                broadcastTerminalSnapshot(allocator, history, s.id);
            }
        }
    }
}

fn appendSessionJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: SessionInfo) !void {
    try out.appendSlice(allocator, "{");
    try out.writer(allocator).print("\"id\":{d},", .{s.id});
    try protocol.appendJsonStringField(allocator, out, "state", stateString(s.state));
    try out.appendSlice(allocator, ",");
    try protocol.appendJsonStringField(allocator, out, "command", s.command);
    try out.appendSlice(allocator, ",");
    try protocol.appendJsonStringField(allocator, out, "cwd", s.cwd);

    try out.appendSlice(allocator, ",\"tasks\":[");
    for (s.tasks, 0..) |task, ti| {
        if (ti > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{");
        try protocol.appendJsonStringField(allocator, out, "id", task.id);
        try out.appendSlice(allocator, ",");
        try protocol.appendJsonStringField(allocator, out, "subject", task.subject);
        try out.appendSlice(allocator, ",\"completed\":");
        try out.appendSlice(allocator, if (task.completed) "true" else "false");
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]");

    try out.appendSlice(allocator, ",\"subagents\":[");
    for (s.subagents, 0..) |sa, si| {
        if (si > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "{");
        try protocol.appendJsonStringField(allocator, out, "id", sa.id);
        try out.appendSlice(allocator, ",");
        try protocol.appendJsonStringField(allocator, out, "type", sa.agent_type);
        try out.appendSlice(allocator, ",\"completed\":");
        try out.appendSlice(allocator, if (sa.completed) "true" else "false");
        try out.appendSlice(allocator, ",\"elapsed_ms\":");
        try out.writer(allocator).print("{d}", .{sa.elapsed_ms});
        try out.appendSlice(allocator, "}");
    }
    try out.appendSlice(allocator, "]");

    if (s.current_activity) |act| {
        try out.appendSlice(allocator, ",\"activity\":{");
        try protocol.appendJsonStringField(allocator, out, "tool_name", act.tool_name);
        try out.appendSlice(allocator, "}");
    } else {
        try out.appendSlice(allocator, ",\"activity\":null");
    }

    if (s.last_message.len > 0) {
        try out.appendSlice(allocator, ",");
        try protocol.appendJsonStringField(allocator, out, "last_message", s.last_message);
    } else {
        try out.appendSlice(allocator, ",\"last_message\":null");
    }

    if (s.prompt_summary.len > 0 or s.prompt_options.len > 0 or s.prompt_questions.len > 0) {
        try out.appendSlice(allocator, ",\"prompt\":{");
        try protocol.appendJsonStringField(allocator, out, "summary", s.prompt_summary);
        try out.appendSlice(allocator, ",\"options\":[");
        for (s.prompt_options, 0..) |opt, oi| {
            if (oi > 0) try out.appendSlice(allocator, ",");
            try protocol.appendJsonStringValue(allocator, out, opt);
        }
        try out.appendSlice(allocator, "]");
        if (s.prompt_questions.len > 0) {
            try out.appendSlice(allocator, ",\"questions\":[");
            for (s.prompt_questions, 0..) |q, qi| {
                if (qi > 0) try out.appendSlice(allocator, ",");
                try out.appendSlice(allocator, "{");
                try protocol.appendJsonStringField(allocator, out, "question", q.question);
                try out.appendSlice(allocator, ",\"options\":[");
                for (q.options, 0..) |opt, oi| {
                    if (oi > 0) try out.appendSlice(allocator, ",");
                    try protocol.appendJsonStringValue(allocator, out, opt);
                }
                try out.appendSlice(allocator, "]}");
            }
            try out.appendSlice(allocator, "]");
        }
        try out.appendSlice(allocator, "}");
    } else {
        try out.appendSlice(allocator, ",\"prompt\":null");
    }

    try out.appendSlice(allocator, "}");
}

fn stateString(state: session_mod.SessionState) []const u8 {
    return switch (state) {
        .running => "running",
        .waiting => "waiting",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .stopped => "stopped",
    };
}

fn handleDataChannelMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    session_manager: *SessionManager,
    auth: *Auth,
) void {
    var parsed_msg = protocol.parseClientMessage(allocator, raw) catch {
        logStderr("[kite-dc] Failed to parse data channel message", .{});
        return;
    };
    defer parsed_msg.deinit();
    const msg = parsed_msg.value();

    if (std.mem.eql(u8, msg.type, "auth")) {
        logStderr("[kite-dc] Handling auth message (has token={})", .{msg.token != null});
        handleAuthMessage(allocator, msg, auth, session_manager);
    } else if (std.mem.eql(u8, msg.type, "terminal_input")) {
        const session_id = msg.session_id orelse 1;
        if (msg.data) |data| {
            session_manager.writeToSession(session_id, data) catch {};
        }
    } else if (std.mem.eql(u8, msg.type, "resize")) {
        const session_id = msg.session_id orelse 1;
        const rows = msg.rows orelse return;
        const cols = msg.cols orelse return;
        _ = session_manager.resizeSession(session_id, rows, cols);
    } else if (std.mem.eql(u8, msg.type, "request_snapshot")) {
        const session_id = msg.session_id orelse return;
        logStderr("[kite-dc] request_snapshot for session {d}", .{session_id});
        if (session_manager.getTerminalSnapshot(allocator, session_id)) |history| {
            defer allocator.free(history);
            logStderr("[kite-dc] snapshot size: {d} bytes", .{history.len});
            if (history.len > 0) {
                broadcastTerminalSnapshot(allocator, history, session_id);
            }
        }
    } else if (std.mem.eql(u8, msg.type, "prompt_response")) {
        const session_id = msg.session_id orelse 1;
        const text = msg.text orelse msg.data orelse "";
        session_manager.resolvePromptResponse(session_id, text);
    } else if (std.mem.eql(u8, msg.type, "create_session")) {
        handleCreateSession(allocator, raw, session_manager);
    } else if (std.mem.eql(u8, msg.type, "delete_session")) {
        const session_id = msg.session_id orelse return;
        session_manager.destroySession(session_id);
        const result = protocol.encodeDeleteSessionResult(allocator, session_id, true) catch return;
        defer allocator.free(result);
        broadcastViaRtc(result);
    } else if (std.mem.eql(u8, msg.type, "ping")) {
        broadcastViaRtc(protocol.encodePong());
    } else if (std.mem.eql(u8, msg.type, "request_sync")) {
        logStderr("[kite-dc] request_sync received", .{});
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
    }
}

fn handleAuthMessage(allocator: std.mem.Allocator, msg: protocol.ClientMessage, auth: *Auth, session_manager: *SessionManager) void {
    if (auth.disabled) {
        const result = protocol.encodeAuthResult(allocator, true, "") catch return;
        defer allocator.free(result);
        broadcastViaRtc(result);
        markAllPeersAuthenticated();
        return;
    }

    const token = msg.token orelse {
        const result = protocol.encodeAuthResult(allocator, false, "") catch return;
        defer allocator.free(result);
        broadcastViaRtc(result);
        return;
    };

    // Try as setup secret first (exchange for session token)
    if (auth.validateSetupSecret(token)) |session_token_hex| {
        logStderr("[kite-auth] Setup secret valid, sending session token", .{});
        const result = protocol.encodeAuthResult(allocator, true, &session_token_hex) catch return;
        defer allocator.free(result);
        broadcastViaRtc(result);
        // Send sessions_sync + terminal snapshots after successful auth
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
        markAllPeersAuthenticated();
        return;
    }

    // Try as session token
    if (auth.validateSessionToken(token)) {
        logStderr("[kite-auth] Session token valid", .{});
        const result = protocol.encodeAuthResult(allocator, true, token) catch return;
        defer allocator.free(result);
        broadcastViaRtc(result);
        // Send sessions_sync + terminal snapshots after successful auth
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
        markAllPeersAuthenticated();
        return;
    }

    // Invalid token
    logStderr("[kite-auth] Token invalid (len={d})", .{token.len});
    const result = protocol.encodeAuthResult(allocator, false, "") catch return;
    defer allocator.free(result);
    broadcastViaRtc(result);
}

fn handleCreateSession(allocator: std.mem.Allocator, raw: []const u8, session_manager: *SessionManager) void {
    const parsed = std.json.parseFromSlice(struct {
        command: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        rows: ?u16 = null,
        cols: ?u16 = null,
    }, allocator, raw, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const opts = parsed.value;

    const session_id = session_manager.createSession(.{
        .command = opts.command orelse "claude",
        .cwd = opts.cwd orelse "",
        .rows = opts.rows orelse 24,
        .cols = opts.cols orelse 80,
    }) catch return;

    const result = protocol.encodeCreateSessionResult(allocator, session_id) catch return;
    defer allocator.free(result);
    broadcastViaRtc(result);
}

var sigwinch_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigwinch(_: c_int) callconv(.c) void {
    sigwinch_received.store(true, .release);
}

fn runRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};
    var positional_cmd: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            cli.printRunHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--cmd")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--cmd <CMD>", "run", "kite run --cmd <CMD>");
                return;
            }
            config.command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--attach")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--attach <ID>", "run", "kite run --attach <ID>");
                return;
            }
            config.attach_id = std.fmt.parseInt(u64, args[i + 1], 10) catch null;
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const run_opts = [_][]const u8{ "--cmd", "--attach" };
            cli.printUnknownOption(args[i], &run_opts, "run");
            return;
        } else {
            // Positional argument: treat as command (with its args)
            positional_cmd = args[i];
        }
    }

    // Positional command takes precedence if --cmd was not explicitly set
    if (positional_cmd) |cmd| {
        if (std.mem.eql(u8, config.command, "claude")) {
            config.command = cmd;
        }
    }

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Step 1: Create session via local IPC (include terminal size)
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

        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&cwd_buf) catch "";
        const ipc_stream = std.net.connectUnixSocket(hooks.IPC_SOCKET_PATH) catch {
            try stdout.print("Cannot connect to kite daemon. Is it running? (kite start)\n", .{});
            try stdout.flush();
            return;
        };
        defer ipc_stream.close();

        const create_cmd = try std.fmt.allocPrint(allocator, "create_session\n{s}\n{s}\n{d}\n{d}\n", .{ config.command, cwd, term_rows, term_cols });
        defer allocator.free(create_cmd);
        ipc_stream.writeAll(create_cmd) catch {
            try stdout.print("Failed to create session via daemon IPC.\n", .{});
            try stdout.flush();
            return;
        };

        var resp_buf: [64]u8 = undefined;
        const resp_n = ipc_stream.read(&resp_buf) catch 0;
        if (resp_n == 0) {
            try stdout.print("Failed to create session via daemon IPC.\n", .{});
            try stdout.flush();
            return;
        }
        session_id = std.fmt.parseInt(u64, std.mem.trim(u8, resp_buf[0..resp_n], " \r\n"), 10) catch {
            try stdout.print("Failed to parse session id from daemon.\n", .{});
            try stdout.flush();
            return;
        };
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

    // Disable mouse tracking modes that the child process may have enabled.
    // Without this, the terminal keeps reporting mouse events as garbled text.
    _ = posix.write(stdout_fd, "\x1b[?1000l" // disable normal mouse tracking
        ++ "\x1b[?1002l" // disable button-event tracking
        ++ "\x1b[?1003l" // disable all-motion tracking
        ++ "\x1b[?1006l" // disable SGR extended mouse mode
        ++ "\x1b[?25h" // ensure cursor is visible
    ) catch {};

    try stdout.print("\n  Session ended.\n", .{});
    try stdout.flush();
}

fn runIpcListener(allocator: std.mem.Allocator, session_manager: *SessionManager) void {
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
        const is_attach = handleIpcConnection(allocator, conn, session_manager);
        if (!is_attach) {
            posix.close(conn);
        }
    }
}

/// Returns true if this is an attach connection (long-lived, caller should NOT close).
fn handleIpcConnection(allocator: std.mem.Allocator, conn: posix.fd_t, session_manager: *SessionManager) bool {
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

    if (std.mem.eql(u8, event_name, "create_session")) {
        const command = lines.next() orelse return false;
        const cwd = lines.next() orelse return false;
        const rows_str = lines.next() orelse return false;
        const cols_str = lines.next() orelse return false;
        const rows = std.fmt.parseInt(u16, std.mem.trim(u8, rows_str, " \r"), 10) catch 24;
        const cols = std.fmt.parseInt(u16, std.mem.trim(u8, cols_str, " \r"), 10) catch 80;

        const session_id = session_manager.createSession(.{
            .command = std.mem.trimRight(u8, command, "\r"),
            .cwd = std.mem.trimRight(u8, cwd, "\r"),
            .rows = rows,
            .cols = cols,
        }) catch {
            _ = posix.write(conn, "error\n") catch {};
            return false;
        };

        const response = std.fmt.allocPrint(allocator, "{d}\n", .{session_id}) catch return false;
        defer allocator.free(response);
        _ = posix.write(conn, response) catch {};
        return false;
    }

    // Handle "attach" command — long-lived terminal relay connection
    if (std.mem.eql(u8, event_name, "attach")) {
        const sid_str = lines.next() orelse return false;
        const session_id = std.fmt.parseInt(u64, std.mem.trim(u8, sid_str, " \r"), 10) catch 1;

        // Verify session exists before attaching
        if (!session_manager.sessionExists(session_id)) {
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
        if (session_manager.getTerminalSnapshot(allocator, session_id)) |history| {
            defer allocator.free(history);
            if (history.len > 0) {
                _ = posix.write(conn, history) catch {};
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

    // Normal hook event handling — read remaining data before parsing
    // The first read may not have received the full JSON body.
    while (total < buf.len) {
        var poll_fds = [1]posix.pollfd{
            .{ .fd = conn, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&poll_fds, 50) catch break;
        if (ready == 0) break;
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    // Re-parse full data to get rest (JSON body) after all reads complete
    const full_data = buf[0..total];
    var full_lines = std.mem.splitScalar(u8, full_data, '\n');
    _ = full_lines.next(); // event_name (already parsed above)
    _ = full_lines.next(); // length
    const rest = full_lines.rest();

    var tool_name: []const u8 = "";
    var session_id: u64 = 1;
    if (std.json.parseFromSlice(hooks.HookInput, allocator, rest, .{ .ignore_unknown_fields = true })) |parsed| {
        if (parsed.value.tool_name) |t| tool_name = t;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }
        defer parsed.deinit();
    } else |_| {}

    // Log raw hook request for mock API replay
    logHookRequest(allocator, event_name, rest);

    session_manager.handleHookEvent(session_id, event_name, rest);

    logStderr("[kite-ipc] hook={s} tool={s} session_id={d}", .{ event_name, tool_name, session_id });

    if (std.mem.eql(u8, event_name, "PreToolUse")) {
        // PreToolUse: just approve and pass through
        _ = posix.write(conn, "{}") catch {};
    } else if (std.mem.eql(u8, event_name, "PermissionRequest") and std.mem.eql(u8, tool_name, "AskUserQuestion")) {
        // PermissionRequest/AskUserQuestion: spawn thread to block and return answer.
        // We already called handleHookEvent above (which set state to .asking and broadcast).
        // Now we need to create PendingAsk, wait for user answer, return hook output.
        const pa = session_manager.createPendingAsk(session_id) catch null;
        if (pa) |pending| {
            pending.tool_input_json = protocol.extractToolInputJson(allocator, rest);
        }

        // Spawn thread so IPC listener isn't blocked for other events
        const thread = std.Thread.spawn(.{}, handlePermissionRequestIpc, .{ allocator, session_manager, session_id, conn }) catch {
            _ = posix.write(conn, "{}") catch {};
            return false;
        };
        thread.detach();
        return true; // Thread owns conn now, caller should NOT close
    }

    return false;
}

/// Thread handler for PermissionRequest/AskUserQuestion via IPC.
/// Blocks until user responds, writes hook output, closes conn.
fn handlePermissionRequestIpc(allocator: std.mem.Allocator, session_manager: *SessionManager, session_id: u64, conn: posix.fd_t) void {
    defer posix.close(conn);

    logStderr("[kite-ipc] Blocking PermissionRequest for AskUserQuestion (session {d})", .{session_id});
    const result = session_manager.waitPendingAsk(session_id);
    if (result) |r| {
        defer allocator.free(r.response);
        defer if (r.tool_input_json.len > 0) allocator.free(r.tool_input_json);

        const hook_output = protocol.buildPermissionHookOutput(allocator, r.tool_input_json, r.response) catch {
            _ = posix.write(conn, "{}") catch {};
            return;
        };
        defer allocator.free(hook_output);
        logStderr("[kite-ipc] PermissionRequest response: {s}", .{hook_output});
        _ = posix.write(conn, hook_output) catch {};
    } else {
        _ = posix.write(conn, "{}") catch {};
    }
}

const log = @import("log.zig");
const cli = @import("cli.zig");
fn logStderr(comptime fmt: []const u8, args: anytype) void {
    log.debug(fmt, args);
}

fn printStatus(msg: []const u8) void {
    const f = std.fs.File.stderr();
    _ = f.write(msg) catch {};
}

const HOOK_LOG_PATH = "/tmp/kite-hooks.jsonl";

fn logHookRequest(allocator: std.mem.Allocator, event_name: []const u8, raw_json: []const u8) void {
    const file = std.fs.cwd().createFile(HOOK_LOG_PATH, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch {};

    const ts = std.time.timestamp();
    // Write one JSONL line: {"ts":...,"event":"...","payload":...}
    // raw_json is already valid JSON, embed it directly
    const line = std.fmt.allocPrint(allocator, "{{\"ts\":{d},\"event\":\"{s}\",\"payload\":{s}}}\n", .{ ts, event_name, if (raw_json.len > 0) raw_json else "{}" }) catch return;
    defer allocator.free(line);
    file.writeAll(line) catch {};
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
        const state = session_manager.getSessionState(session_id) orelse break;
        if (state == .stopped) break;

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
                _ = session_manager.resizeSession(session_id, rows, cols);
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
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            cli.printHookHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--event")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--event <name>", "hook", "kite hook --event <name>");
                return;
            }
            event_name = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const hook_opts = [_][]const u8{"--event"};
            cli.printUnknownOption(args[i], &hook_opts, "hook");
            return;
        }
    }

    if (event_name.len == 0) {
        cli.printMissingOption("--event <name>", "hook", "kite hook --event <name>");
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

fn runSetup(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // Parse --signal-url argument
    var signal_url: []const u8 = "wss://relay.fun.dev/ws";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            cli.printSetupHelp();
            return;
        } else if (std.mem.eql(u8, args[i], "--signal-url")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--signal-url <URL>", "setup", "kite setup --signal-url <URL>");
                return;
            }
            signal_url = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, args[i], "--")) {
            const setup_opts = [_][]const u8{"--signal-url"};
            cli.printUnknownOption(args[i], &setup_opts, "setup");
            return;
        }
    }

    // Write config file
    const home = std.posix.getenv("HOME") orelse return;
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config/kite", .{home});
    defer allocator.free(config_dir);

    // Create parent ~/.config first, then ~/.config/kite
    const parent_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer allocator.free(parent_dir);
    std.fs.makeDirAbsolute(parent_dir) catch {};
    std.fs.makeDirAbsolute(config_dir) catch {};

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{config_dir});
    defer allocator.free(config_path);
    const config_json = try std.fmt.allocPrint(allocator, "{{\"signal_url\":\"{s}\"}}\n", .{signal_url});
    defer allocator.free(config_json);
    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(config_json);

    try stdout.print("Config saved to {s}\n", .{config_path});
    try stdout.print("  signal_url: {s}\n\n", .{signal_url});

    const hooks_config = try hooks.ClaudeCodeConfig.generateHooksConfig(allocator, 7890);
    defer allocator.free(hooks_config);

    try stdout.print("Add the following to your Claude Code settings\n", .{});
    try stdout.print("(~/.claude/settings.json or .claude/settings.json):\n\n", .{});
    try stdout.print("{s}\n", .{hooks_config});
    try stdout.flush();
}

fn runStatus(allocator: std.mem.Allocator, args: []const []const u8) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.printStatusHelp();
            return;
        }
    }

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const is_running = blk: {
        const stream = std.net.connectUnixSocket(hooks.IPC_SOCKET_PATH) catch break :blk false;
        stream.close();
        break :blk true;
    };

    if (is_running) {
        try stdout.print("\n  kite is running\n\n", .{});
    } else {
        try stdout.print("\n  kite is not running\n\n", .{});
    }

    const file_config = readConfigFile(allocator) orelse {
        try stdout.print("  No config found. Run 'kite setup' first.\n\n", .{});
        try stdout.flush();
        return;
    };
    defer allocator.free(file_config.signal_url);
    defer allocator.free(file_config.pairing_code);
    defer allocator.free(file_config.setup_secret);

    if (file_config.pairing_code.len != 6 or file_config.setup_secret.len != 64) {
        try stdout.print("  No pairing code configured. Run 'kite start' to generate one.\n\n", .{});
        try stdout.flush();
        return;
    }

    // Build pairing URL
    const pairing_url = try std.fmt.allocPrint(allocator, "https://kite.fun.dev/remote/#/pair/{s}:{s}", .{ file_config.pairing_code, file_config.setup_secret });
    defer allocator.free(pairing_url);

    // Render QR code
    const qr_mod = @import("qr.zig");
    if (qr_mod.encode(pairing_url)) |qr_result| {
        try qr_mod.renderTerminal(stdout, qr_result, "  ");
        try stdout.print("\n", .{});
    } else |_| {}

    try stdout.print("  {s}\n\n", .{pairing_url});
    try stdout.flush();
}

test {
    _ = @import("cli.zig");
}
