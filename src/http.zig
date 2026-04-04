const std = @import("std");
const http = std.http;
const net = std.net;
const auth_mod = @import("auth.zig");
const protocol = @import("protocol.zig");
const ws_mod = @import("ws.zig");
const SessionManager = @import("session_manager.zig").SessionManager;

fn parseSessionIdFromPath(path: []const u8) ?u64 {
    const prefix = "/api/v1/sessions/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len <= prefix.len) return null;
    const id_str = path[prefix.len..];
    return std.fmt.parseInt(u64, id_str, 10) catch null;
}

const cors_preflight_headers: [3]http.Header = .{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
};

const json_header: [1]http.Header = .{
    .{ .name = "Content-Type", .value = "application/json" },
};

const json_cors_headers: [2]http.Header = .{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    auth: *auth_mod.Auth,
    broadcaster: *ws_mod.WsBroadcaster,
    session_manager: *SessionManager,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    static_dir: ?[]const u8 = null,
    cors_enabled: bool = false,

    fn apiHeaders(self: *const Server) []const http.Header {
        if (self.cors_enabled) return &json_cors_headers;
        return &json_header;
    }

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

        if (self.cors_enabled and head.head.method == .OPTIONS) {
            head.respond("", .{
                .status = .no_content,
                .extra_headers = &cors_preflight_headers,
            }) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/ws")) {
            self.handleWebSocket(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/auth") and head.head.method == .POST) {
            self.handleAuth(&head) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/v1/hooks") and head.head.method == .POST) {
            self.handleHttpHook(&head) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/v1/sessions") and head.head.method == .POST) {
            self.handleCreateSession(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/sessions/") and std.mem.endsWith(u8, path, "/terminal")) {
            self.handleTerminalSnapshot(&head, path) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/sessions/") and std.mem.endsWith(u8, path, "/events")) {
            self.handleSessionEvents(&head, path) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/sessions")) {
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
        if (self.auth.disabled) client.authenticated = true;
        try self.broadcaster.addClient(&client);
        defer self.broadcaster.removeClient(&client);

        // Send initial terminal history
        if (self.session_manager.getSession(1)) |session| {
            const history = session.terminal_buffer.slice();
            if (history.first.len > 0) {
                const msg = protocol.encodeTerminalOutput(self.allocator, history.first, 1) catch null;
                if (msg) |m| {
                    defer self.allocator.free(m);
                    client.send(m);
                }
            }
            if (history.second.len > 0) {
                const msg = protocol.encodeTerminalOutput(self.allocator, history.second, 1) catch null;
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
            try head.respond("{\"error\":\"invalid json\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        };
        defer parsed.deinit();

        const token_result = self.auth.validateSetupToken(parsed.value.setup_token);
        if (token_result) |session_token| {
            const response = std.fmt.allocPrint(self.allocator, "{{\"success\":true,\"token\":\"{s}\"}}", .{session_token}) catch return;
            defer self.allocator.free(response);
            try head.respond(response, .{
                .extra_headers = self.apiHeaders(),
            });
        } else {
            try head.respond("{\"error\":\"invalid or expired token\"}", .{
                .status = .unauthorized,
                .extra_headers = self.apiHeaders(),
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
                .extra_headers = self.apiHeaders(),
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
                .extra_headers = self.apiHeaders(),
            });
            return;
        };

        const response = std.fmt.allocPrint(self.allocator, "{{\"session_id\":{d}}}", .{session_id}) catch return;
        defer self.allocator.free(response);
        try head.respond(response, .{
            .extra_headers = self.apiHeaders(),
        });
    }

    fn handleHttpHook(self: *Server, head: *http.Server.Request) !void {
        var body_buf: [8192]u8 = undefined;
        const io_reader = head.readerExpectNone(&body_buf);
        var body: [8192]u8 = undefined;
        var bufs: [1][]u8 = .{&body};
        const body_len = io_reader.readVec(&bufs) catch 0;
        const body_slice = body[0..body_len];

        const HookPayload = struct {
            hook_event_name: []const u8 = "",
            session_id: []const u8 = "",
            tool_name: ?[]const u8 = null,
        };
        const parsed = std.json.parseFromSlice(HookPayload, self.allocator, body_slice, .{
            .ignore_unknown_fields = true,
        }) catch {
            try head.respond("{\"error\":\"invalid json\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };
        defer parsed.deinit();

        const event_name = parsed.value.hook_event_name;
        if (event_name.len == 0) {
            try head.respond("{\"error\":\"missing hook_event_name\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        }

        var session_id: u64 = 1;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }

        // Broadcast hook event to WebSocket clients
        const tool_name = parsed.value.tool_name orelse "";
        const msg = protocol.encodeHookEvent(self.allocator, event_name, tool_name, body_slice, session_id) catch null;
        if (msg) |m| {
            defer self.allocator.free(m);
            self.broadcaster.broadcast(m);
        }

        // Update session state
        self.session_manager.handleHookEvent(session_id, event_name, body_slice);

        try head.respond("{\"ok\":true}", .{
            .extra_headers = self.apiHeaders(),
        });
    }

    fn handleSessionsApi(self: *Server, head: *http.Server.Request) !void {
        const path = head.head.target;

        // GET /api/v1/sessions — list all
        if (std.mem.eql(u8, path, "/api/v1/sessions")) {
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
                try json_buf.appendSlice(self.allocator, entry[0 .. entry.len - 1]); // strip trailing }
                // tasks array
                try json_buf.appendSlice(self.allocator, ",\"tasks\":[");
                for (s.tasks, 0..) |task, ti| {
                    if (ti > 0) try json_buf.appendSlice(self.allocator, ",");
                    const t_entry = std.fmt.allocPrint(self.allocator,
                        \\{{"id":"{s}","subject":"{s}","completed":{s}}}
                    , .{ task.id, task.subject, if (task.completed) "true" else "false" }) catch continue;
                    defer self.allocator.free(t_entry);
                    try json_buf.appendSlice(self.allocator, t_entry);
                }
                try json_buf.appendSlice(self.allocator, "]");
                // subagents array
                try json_buf.appendSlice(self.allocator, ",\"subagents\":[");
                for (s.subagents, 0..) |sa, si| {
                    if (si > 0) try json_buf.appendSlice(self.allocator, ",");
                    const sa_entry = std.fmt.allocPrint(self.allocator,
                        \\{{"id":"{s}","type":"{s}","completed":{s},"elapsed_ms":{d}}}
                    , .{ sa.id, sa.agent_type, if (sa.completed) "true" else "false", sa.elapsed_ms }) catch continue;
                    defer self.allocator.free(sa_entry);
                    try json_buf.appendSlice(self.allocator, sa_entry);
                }
                try json_buf.appendSlice(self.allocator, "]");
                // activity
                if (s.current_activity) |act| {
                    const act_entry = std.fmt.allocPrint(self.allocator,
                        \\,"activity":{{"tool_name":"{s}"}}
                    , .{act.tool_name}) catch {
                        try json_buf.appendSlice(self.allocator, ",\"activity\":null");
                        try json_buf.appendSlice(self.allocator, "}");
                        continue;
                    };
                    defer self.allocator.free(act_entry);
                    try json_buf.appendSlice(self.allocator, act_entry);
                } else {
                    try json_buf.appendSlice(self.allocator, ",\"activity\":null");
                }
                try json_buf.appendSlice(self.allocator, "}");
            }
            try json_buf.appendSlice(self.allocator, "]");
            try head.respond(json_buf.items, .{
                .extra_headers = self.apiHeaders(),
            });
            return;
        }

        // /api/v1/sessions/:id — parse ID
        const session_id = parseSessionIdFromPath(path) orelse {
            try head.respond("{\"error\":\"invalid session id\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };

        // DELETE /api/v1/sessions/:id
        if (head.head.method == .DELETE) {
            self.session_manager.destroySession(session_id);
            try head.respond("{\"ok\":true}", .{
                .extra_headers = self.apiHeaders(),
            });
            return;
        }

        // GET /api/v1/sessions/:id
        if (self.session_manager.getSession(session_id)) |session| {
            const state_str = switch (session.state) {
                .starting => "starting",
                .running => "running",
                .waiting_input => "waiting_input",
                .stopped => "stopped",
            };
            var json_buf: std.ArrayList(u8) = .empty;
            defer json_buf.deinit(self.allocator);
            const header = std.fmt.allocPrint(self.allocator,
                \\{{"id":{d},"state":"{s}","command":"{s}","cwd":"{s}"}}
            , .{ session.id, state_str, session.command, session.cwd }) catch return;
            defer self.allocator.free(header);
            try json_buf.appendSlice(self.allocator, header[0 .. header.len - 1]); // strip trailing }
            // tasks
            try json_buf.appendSlice(self.allocator, ",\"tasks\":[");
            for (session.tasks.items, 0..) |task, ti| {
                if (ti > 0) try json_buf.appendSlice(self.allocator, ",");
                const t_entry = std.fmt.allocPrint(self.allocator,
                    \\{{"id":"{s}","subject":"{s}","completed":{s}}}
                , .{ task.id, task.subject, if (task.completed) "true" else "false" }) catch continue;
                defer self.allocator.free(t_entry);
                try json_buf.appendSlice(self.allocator, t_entry);
            }
            try json_buf.appendSlice(self.allocator, "]");
            // subagents
            try json_buf.appendSlice(self.allocator, ",\"subagents\":[");
            for (session.subagents.items, 0..) |sa, si| {
                if (si > 0) try json_buf.appendSlice(self.allocator, ",");
                const sa_entry = std.fmt.allocPrint(self.allocator,
                    \\{{"id":"{s}","type":"{s}","completed":{s},"elapsed_ms":{d}}}
                , .{ sa.id, sa.agent_type, if (sa.completed) "true" else "false", sa.elapsed_ms }) catch continue;
                defer self.allocator.free(sa_entry);
                try json_buf.appendSlice(self.allocator, sa_entry);
            }
            try json_buf.appendSlice(self.allocator, "]");
            // activity
            if (session.current_activity) |act| {
                const act_entry = std.fmt.allocPrint(self.allocator,
                    \\,"activity":{{"tool_name":"{s}"}}
                , .{act.tool_name}) catch {
                    try json_buf.appendSlice(self.allocator, ",\"activity\":null}");
                    try head.respond(json_buf.items, .{ .extra_headers = self.apiHeaders() });
                    return;
                };
                defer self.allocator.free(act_entry);
                try json_buf.appendSlice(self.allocator, act_entry);
            } else {
                try json_buf.appendSlice(self.allocator, ",\"activity\":null");
            }
            try json_buf.appendSlice(self.allocator, "}");
            try head.respond(json_buf.items, .{
                .extra_headers = self.apiHeaders(),
            });
        } else {
            try head.respond("{\"error\":\"session not found\"}", .{
                .status = .not_found,
                .extra_headers = self.apiHeaders(),
            });
        }
    }

    fn handleSessionEvents(self: *Server, head: *http.Server.Request, path: []const u8) !void {
        const prefix = "/api/v1/sessions/";
        const suffix = "/events";
        if (path.len <= prefix.len + suffix.len) {
            try head.respond("{\"error\":\"invalid path\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        }
        const id_str = path[prefix.len .. path.len - suffix.len];
        const session_id = std.fmt.parseInt(u64, id_str, 10) catch {
            try head.respond("{\"error\":\"invalid session id\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        };

        const session = self.session_manager.getSession(session_id) orelse {
            try head.respond("{\"error\":\"session not found\"}", .{ .status = .not_found, .extra_headers = self.apiHeaders() });
            return;
        };

        // Build JSON array of events
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"events\":[");
        for (session.hook_events.items, 0..) |ev, i| {
            if (i > 0) try json_buf.appendSlice(self.allocator, ",");
            const entry = try std.fmt.allocPrint(self.allocator,
                \\{{"event":"{s}","tool":"{s}","ts":{d}}}
            , .{ ev.event_name, ev.tool_name, ev.timestamp });
            defer self.allocator.free(entry);
            try json_buf.appendSlice(self.allocator, entry);
        }
        try json_buf.appendSlice(self.allocator, "]}");
        try head.respond(json_buf.items, .{ .extra_headers = self.apiHeaders() });
    }

    fn handleTerminalSnapshot(self: *Server, head: *http.Server.Request, path: []const u8) !void {
        // Extract session ID from /api/v1/sessions/<id>/terminal
        const prefix = "/api/v1/sessions/";
        const suffix = "/terminal";
        if (path.len <= prefix.len + suffix.len) {
            try head.respond("{\"error\":\"invalid path\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        }
        const id_str = path[prefix.len .. path.len - suffix.len];
        const session_id = std.fmt.parseInt(u64, id_str, 10) catch {
            try head.respond("{\"error\":\"invalid session id\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        };

        const session = self.session_manager.getSession(session_id) orelse {
            try head.respond("{\"error\":\"session not found\"}", .{ .status = .not_found, .extra_headers = self.apiHeaders() });
            return;
        };

        // Get terminal buffer contents and base64 encode
        const slice = session.terminal_buffer.slice();
        const total_len = slice.first.len + slice.second.len;

        if (total_len == 0) {
            try head.respond("{\"data\":\"\"}", .{ .extra_headers = self.apiHeaders() });
            return;
        }

        // Combine the two parts of the ring buffer
        const combined = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(combined);
        @memcpy(combined[0..slice.first.len], slice.first);
        @memcpy(combined[slice.first.len..], slice.second);

        // Base64 encode
        const b64_len = std.base64.standard.Encoder.calcSize(total_len);
        const b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64);
        const encoded = std.base64.standard.Encoder.encode(b64, combined);

        const response = try std.fmt.allocPrint(self.allocator, "{{\"data\":\"{s}\",\"session_id\":{d}}}", .{ encoded, session_id });
        defer self.allocator.free(response);
        try head.respond(response, .{ .extra_headers = self.apiHeaders() });
    }

    fn serveStaticFile(self: *Server, head: *http.Server.Request, path: []const u8) !void {
        const dir = self.static_dir orelse {
            try head.respond("{\"error\":\"not found\"}", .{
                .status = .not_found,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };

        const serve_path = if (std.mem.eql(u8, path, "/")) "index.html" else if (path.len > 1) path[1..] else path;

        var path_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, serve_path }) catch {
            try head.respond("Not Found", .{ .status = .not_found });
            return;
        };

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            // SPA fallback: serve index.html for unknown paths
            var index_buf: [1024]u8 = undefined;
            const index_path = std.fmt.bufPrint(&index_buf, "{s}/index.html", .{dir}) catch {
                try head.respond("Not Found", .{ .status = .not_found });
                return;
            };
            const index_file = std.fs.openFileAbsolute(index_path, .{}) catch {
                try head.respond("Not Found", .{ .status = .not_found });
                return;
            };
            defer index_file.close();

            var buf: [65536]u8 = undefined;
            const n = index_file.readAll(&buf) catch {
                try head.respond("Read Error", .{ .status = .internal_server_error });
                return;
            };
            try head.respond(buf[0..n], .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
            });
            return;
        };
        defer file.close();

        var buf: [65536]u8 = undefined;
        const n = file.readAll(&buf) catch {
            try head.respond("Read Error", .{ .status = .internal_server_error });
            return;
        };

        const content_type = if (std.mem.endsWith(u8, serve_path, ".html"))
            "text/html; charset=utf-8"
        else if (std.mem.endsWith(u8, serve_path, ".js"))
            "application/javascript"
        else if (std.mem.endsWith(u8, serve_path, ".css"))
            "text/css"
        else if (std.mem.endsWith(u8, serve_path, ".json"))
            "application/json"
        else if (std.mem.endsWith(u8, serve_path, ".svg"))
            "image/svg+xml"
        else if (std.mem.endsWith(u8, serve_path, ".png"))
            "image/png"
        else if (std.mem.endsWith(u8, serve_path, ".ico"))
            "image/x-icon"
        else
            "application/octet-stream";

        try head.respond(buf[0..n], .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = content_type }},
        });
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }
};
