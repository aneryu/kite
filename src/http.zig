const std = @import("std");
const http = std.http;
const net = std.net;
const web = @import("web.zig");
const auth_mod = @import("auth.zig");
const protocol = @import("protocol.zig");
const ws_mod = @import("ws.zig");
const session_mod = @import("session.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    auth: *auth_mod.Auth,
    broadcaster: *ws_mod.WsBroadcaster,
    session: *session_mod.Session,
    on_terminal_input: *const fn ([]const u8) void,
    on_resize: *const fn (u16, u16) void,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: []const u8,
        port: u16,
        a: *auth_mod.Auth,
        broadcaster: *ws_mod.WsBroadcaster,
        sess: *session_mod.Session,
        on_input: *const fn ([]const u8) void,
        on_resize_cb: *const fn (u16, u16) void,
    ) !Server {
        const address = try net.Address.parseIp(bind_addr, port);
        return .{
            .allocator = allocator,
            .address = address,
            .auth = a,
            .broadcaster = broadcaster,
            .session = sess,
            .on_terminal_input = on_input,
            .on_resize = on_resize_cb,
        };
    }

    pub fn run(self: *Server) !void {
        var server = try self.address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        while (self.running.load(.acquire)) {
            const conn = server.accept() catch continue;
            const self_ptr = self;
            _ = std.Thread.spawn(.{}, handleConnection, .{ self_ptr, conn.stream }) catch {
                conn.stream.close();
                continue;
            };
        }
    }

    fn handleConnection(self: *Server, stream: net.Stream) void {
        defer stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var net_reader = stream.reader(&read_buf);
        var net_writer = stream.writer(&write_buf);

        var http_server = http.Server.init(net_reader.interface(), &net_writer.interface);
        var head = http_server.receiveHead() catch return;

        const path = head.head.target;

        if (std.mem.startsWith(u8, path, "/ws")) {
            self.handleWebSocket(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/auth") and head.head.method == .POST) {
            self.handleAuth(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/session")) {
            self.handleSessionApi(&head) catch {};
            return;
        }

        self.serveStaticFile(&head, path) catch {};
    }

    fn handleWebSocket(self: *Server, head: *http.Server.Request) !void {
        const upgrade = head.upgradeRequested();
        const ws_key = switch (upgrade) {
            .websocket => |k| k orelse return,
            else => return,
        };
        var ws = try head.respondWebSocket(.{ .key = ws_key });

        var client = ws_mod.WsClient{ .ws = ws };
        try self.broadcaster.addClient(&client);
        defer self.broadcaster.removeClient(&client);

        // Send initial terminal history
        const history = self.session.terminal_buffer.slice();
        if (history.first.len > 0) {
            const msg = protocol.encodeTerminalOutput(self.allocator, history.first) catch null;
            if (msg) |m| {
                defer self.allocator.free(m);
                client.send(m);
            }
        }
        if (history.second.len > 0) {
            const msg = protocol.encodeTerminalOutput(self.allocator, history.second) catch null;
            if (msg) |m| {
                defer self.allocator.free(m);
                client.send(m);
            }
        }

        while (true) {
            const message = ws.readSmallMessage() catch break;
            const data = message.data;

            var parsed = protocol.parseClientMessage(self.allocator, data) catch continue;
            defer parsed.deinit();
            const msg = parsed.value();

            if (std.mem.eql(u8, msg.@"type", "auth_token")) {
                if (msg.token) |token| {
                    client.authenticated = self.auth.validateSessionToken(token);
                    const result = protocol.encodeAuthResult(self.allocator, client.authenticated, "") catch continue;
                    defer self.allocator.free(result);
                    client.send(result);
                }
                continue;
            }

            if (!client.authenticated) continue;

            if (std.mem.eql(u8, msg.@"type", "terminal_input")) {
                if (msg.data) |input_data| {
                    self.on_terminal_input(input_data);
                }
            } else if (std.mem.eql(u8, msg.@"type", "resize")) {
                if (msg.cols != null and msg.rows != null) {
                    self.on_resize(msg.rows.?, msg.cols.?);
                }
            }
        }
    }

    fn handleAuth(self: *Server, head: *http.Server.Request) !void {
        var body_buf: [2048]u8 = undefined;
        const io_reader = head.readerExpectNone(&body_buf);

        var body: [2048]u8 = undefined;
        var bufs: [1][]u8 = .{&body};
        const body_len = io_reader.readVec(&bufs) catch 0;
        const body_slice = body[0..body_len];

        const AuthReq = struct { setup_token: []const u8 = "" };
        const parsed = std.json.parseFromSlice(AuthReq, self.allocator, body_slice, .{ .ignore_unknown_fields = true }) catch {
            try head.respond("", .{ .status = .bad_request });
            return;
        };
        defer parsed.deinit();

        const token_result = self.auth.validateSetupToken(parsed.value.setup_token);
        if (token_result) |session_token| {
            const response = std.fmt.allocPrint(self.allocator, "{{\"success\":true,\"token\":\"{s}\"}}", .{session_token}) catch return;
            defer self.allocator.free(response);
            try head.respond(response, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        } else {
            try head.respond("{\"success\":false}", .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        }
    }

    fn handleSessionApi(self: *Server, head: *http.Server.Request) !void {
        const state_str = switch (self.session.state) {
            .starting => "starting",
            .running => "running",
            .waiting_approval => "waiting_approval",
            .stopped => "stopped",
        };
        const response = protocol.encodeSessionStatus(self.allocator, state_str, self.session.id) catch return;
        defer self.allocator.free(response);
        try head.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
    }

    fn serveStaticFile(_: *Server, head: *http.Server.Request, path: []const u8) !void {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            try head.respond(web.index_html, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
            });
        } else {
            try head.respond("Not Found", .{ .status = .not_found });
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }
};
