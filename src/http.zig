const std = @import("std");
const http = std.http;
const net = std.net;
const web = @import("web.zig");
const auth_mod = @import("auth.zig");
const protocol = @import("protocol.zig");
const ws_mod = @import("ws.zig");
const SessionManager = @import("session_manager.zig").SessionManager;

fn parseSessionIdFromPath(path: []const u8) ?u64 {
    const prefix = "/api/sessions/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len <= prefix.len) return null;
    const id_str = path[prefix.len..];
    return std.fmt.parseInt(u64, id_str, 10) catch null;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    auth: *auth_mod.Auth,
    broadcaster: *ws_mod.WsBroadcaster,
    session_manager: *SessionManager,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: []const u8,
        port: u16,
        a: *auth_mod.Auth,
        broadcaster: *ws_mod.WsBroadcaster,
        session_manager: *SessionManager,
    ) !Server {
        const address = try net.Address.parseIp(bind_addr, port);
        return .{
            .allocator = allocator,
            .address = address,
            .auth = a,
            .broadcaster = broadcaster,
            .session_manager = session_manager,
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

        if (std.mem.eql(u8, path, "/api/sessions") and head.head.method == .POST) {
            self.handleCreateSession(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/sessions")) {
            self.handleSessionsApi(&head) catch {};
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
        if (self.session_manager.getSession(1)) |session| {
            const history = session.terminal_buffer.slice();
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
                    const sid = msg.session_id orelse 1;
                    self.session_manager.writeToSession(sid, input_data) catch {};
                }
            } else if (std.mem.eql(u8, msg.@"type", "resize")) {
                if (msg.cols != null and msg.rows != null) {
                    const sid = msg.session_id orelse 1;
                    self.session_manager.resizeSession(sid, msg.rows.?, msg.cols.?);
                }
            } else if (std.mem.eql(u8, msg.@"type", "prompt_response")) {
                if (msg.text) |text| {
                    const sid = msg.session_id orelse 1;
                    var input_buf: [4097]u8 = undefined;
                    if (text.len < input_buf.len - 1) {
                        @memcpy(input_buf[0..text.len], text);
                        input_buf[text.len] = '\n';
                        self.session_manager.writeToSession(sid, input_buf[0 .. text.len + 1]) catch {};
                    }
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

    fn handleCreateSession(self: *Server, head: *http.Server.Request) !void {
        var body_buf: [2048]u8 = undefined;
        const io_reader = head.readerExpectNone(&body_buf);
        var body: [2048]u8 = undefined;
        var bufs: [1][]u8 = .{&body};
        const body_len = io_reader.readVec(&bufs) catch 0;
        const body_slice = body[0..body_len];

        const CreateReq = struct {
            command: []const u8 = "claude",
            cwd: []const u8 = "",
            rows: u16 = 24,
            cols: u16 = 80,
        };
        const parsed = std.json.parseFromSlice(CreateReq, self.allocator, body_slice, .{
            .ignore_unknown_fields = true,
        }) catch {
            try head.respond("{\"error\":\"invalid json\"}", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        };
        defer parsed.deinit();

        const session_id = self.session_manager.createSession(.{
            .command = parsed.value.command,
            .cwd = parsed.value.cwd,
            .rows = parsed.value.rows,
            .cols = parsed.value.cols,
        }) catch |err| {
            const status: std.http.Status = if (err == error.TooManySessions) .too_many_requests else .internal_server_error;
            const msg = if (err == error.TooManySessions) "{\"error\":\"too many sessions\"}" else "{\"error\":\"failed to create session\"}";
            try head.respond(msg, .{
                .status = status,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        };

        const response = std.fmt.allocPrint(self.allocator, "{{\"session_id\":{d}}}", .{session_id}) catch return;
        defer self.allocator.free(response);
        try head.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
    }

    fn handleSessionsApi(self: *Server, head: *http.Server.Request) !void {
        const path = head.head.target;

        // GET /api/sessions — list all
        if (std.mem.eql(u8, path, "/api/sessions")) {
            const sessions = self.session_manager.listSessions(self.allocator) catch return;
            defer self.allocator.free(sessions);

            var json_buf: std.ArrayList(u8) = .empty;
            defer json_buf.deinit(self.allocator);
            try json_buf.appendSlice(self.allocator, "[");
            for (sessions, 0..) |s, i| {
                if (i > 0) try json_buf.appendSlice(self.allocator, ",");
                const state_str = switch (s.state) {
                    .starting => "starting",
                    .running => "running",
                    .waiting_input => "waiting_input",
                    .stopped => "stopped",
                };
                const entry = std.fmt.allocPrint(self.allocator,
                    \\{{"id":{d},"state":"{s}","command":"{s}","cwd":"{s}"}}
                , .{ s.id, state_str, s.command, s.cwd }) catch continue;
                defer self.allocator.free(entry);
                try json_buf.appendSlice(self.allocator, entry);
            }
            try json_buf.appendSlice(self.allocator, "]");
            try head.respond(json_buf.items, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        }

        // /api/sessions/:id — parse ID
        const session_id = parseSessionIdFromPath(path) orelse {
            try head.respond("{\"error\":\"invalid session id\"}", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        };

        // DELETE /api/sessions/:id
        if (head.head.method == .DELETE) {
            self.session_manager.destroySession(session_id);
            try head.respond("{\"ok\":true}", .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        }

        // GET /api/sessions/:id
        if (self.session_manager.getSession(session_id)) |session| {
            const state_str = switch (session.state) {
                .starting => "starting",
                .running => "running",
                .waiting_input => "waiting_input",
                .stopped => "stopped",
            };
            const response = std.fmt.allocPrint(self.allocator,
                \\{{"id":{d},"state":"{s}","command":"{s}","cwd":"{s}"}}
            , .{ session.id, state_str, session.command, session.cwd }) catch return;
            defer self.allocator.free(response);
            try head.respond(response, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        } else {
            try head.respond("{\"error\":\"session not found\"}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        }
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
