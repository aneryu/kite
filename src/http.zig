const std = @import("std");
const http = std.http;
const net = std.net;
const auth_mod = @import("auth.zig");
const protocol = @import("protocol.zig");
const ws_mod = @import("ws.zig");
const session_manager_mod = @import("session_manager.zig");
const SessionManager = session_manager_mod.SessionManager;
const SessionInfo = session_manager_mod.SessionInfo;

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

    fn log(_: *const Server, comptime fmt: []const u8, args: anytype) void {
        const stderr = std.fs.File.stderr();
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "[kite] " ++ fmt ++ "\n", args) catch return;
        defer std.heap.page_allocator.free(msg);
        _ = stderr.write(msg) catch {};
    }

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
        var req = http_server.receiveHead() catch return;
        const path = req.head.target;

        if (self.cors_enabled and req.head.method == .OPTIONS) {
            req.respond("", .{
                .status = .no_content,
                .extra_headers = &cors_preflight_headers,
            }) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/ws")) {
            self.handleWebSocket(&req) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/v1/auth") and req.head.method == .POST) {
            self.handleAuth(&req) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/v1/hooks") and req.head.method == .POST) {
            self.handleHttpHook(&req) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/") and !self.isAuthorized(&req)) {
            req.respond("{\"error\":\"unauthorized\"}", .{
                .status = .unauthorized,
                .extra_headers = self.apiHeaders(),
            }) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/v1/sessions") and req.head.method == .POST) {
            self.handleCreateSession(&req) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/sessions/") and std.mem.endsWith(u8, path, "/terminal")) {
            self.handleTerminalSnapshot(&req, path) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/v1/sessions")) {
            self.handleSessionsApi(&req) catch {};
            return;
        }

        self.serveStaticFile(&req, path) catch {};
    }

    fn handleWebSocket(self: *Server, req: *http.Server.Request) !void {
        const upgrade = req.upgradeRequested();
        const ws_key = switch (upgrade) {
            .websocket => |k| k orelse return,
            else => return,
        };
        var ws = try req.respondWebSocket(.{ .key = ws_key });

        var client = ws_mod.WsClient{ .ws = ws };
        if (self.auth.disabled) client.authenticated = true;
        try self.broadcaster.addClient(&client);
        defer self.broadcaster.removeClient(&client);

        if (client.authenticated) {
            self.sendSessionsSync(&client);
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
                    if (client.authenticated) {
                        self.sendSessionsSync(&client);
                    }
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
                    _ = self.session_manager.resizeSession(sid, msg.rows.?, msg.cols.?);
                }
            } else if (std.mem.eql(u8, msg.@"type", "prompt_response")) {
                if (msg.text) |text| {
                    const sid = msg.session_id orelse 1;
                    self.session_manager.resolvePromptResponse(sid, text);
                }
            }
        }
    }

    fn handleAuth(self: *Server, req: *http.Server.Request) !void {
        var body_buf: [2048]u8 = undefined;
        const io_reader = req.readerExpectNone(&body_buf);

        var body: [2048]u8 = undefined;
        var bufs: [1][]u8 = .{&body};
        const body_len = io_reader.readVec(&bufs) catch 0;
        const body_slice = body[0..body_len];

        const AuthReq = struct { setup_token: []const u8 = "" };
        const parsed = std.json.parseFromSlice(AuthReq, self.allocator, body_slice, .{ .ignore_unknown_fields = true }) catch {
            try req.respond("{\"error\":\"invalid json\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        };
        defer parsed.deinit();

        const token_result = self.auth.validateSetupToken(parsed.value.setup_token);
        if (token_result) |session_token| {
            const response = std.fmt.allocPrint(self.allocator, "{{\"success\":true,\"token\":\"{s}\"}}", .{session_token}) catch return;
            defer self.allocator.free(response);
            try req.respond(response, .{ .extra_headers = self.apiHeaders() });
        } else {
            try req.respond("{\"error\":\"invalid or expired token\"}", .{
                .status = .unauthorized,
                .extra_headers = self.apiHeaders(),
            });
        }
    }

    fn handleCreateSession(self: *Server, req: *http.Server.Request) !void {
        var body_buf: [2048]u8 = undefined;
        const io_reader = req.readerExpectNone(&body_buf);
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
            try req.respond("{\"error\":\"invalid json\"}", .{
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
            try req.respond(msg, .{ .status = status, .extra_headers = self.apiHeaders() });
            return;
        };

        const response = std.fmt.allocPrint(self.allocator, "{{\"session_id\":{d}}}", .{session_id}) catch return;
        defer self.allocator.free(response);
        try req.respond(response, .{ .extra_headers = self.apiHeaders() });
    }

    fn handleHttpHook(self: *Server, req: *http.Server.Request) !void {
        var body_buf: [8192]u8 = undefined;
        const io_reader = req.readerExpectNone(&body_buf);
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
            try req.respond("{\"error\":\"invalid json\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };
        defer parsed.deinit();

        const event_name = parsed.value.hook_event_name;
        if (event_name.len == 0) {
            try req.respond("{\"error\":\"missing hook_event_name\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        }

        var session_id: u64 = 1;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }

        const tool_name = parsed.value.tool_name orelse "";
        const is_permission_ask = std.mem.eql(u8, event_name, "PermissionRequest") and
            std.mem.eql(u8, tool_name, "AskUserQuestion");

        if (is_permission_ask) {
            const pa = self.session_manager.createPendingAsk(session_id) catch null;
            if (pa) |pending| {
                pending.tool_input_json = protocol.extractToolInputJson(self.allocator, body_slice);
            }
        }

        self.session_manager.handleHookEvent(session_id, event_name, body_slice);

        if (is_permission_ask) {
            const result = self.session_manager.waitPendingAsk(session_id);
            if (result) |r| {
                defer self.allocator.free(r.response);
                defer if (r.tool_input_json.len > 0) self.allocator.free(r.tool_input_json);

                const hook_output = protocol.buildPermissionHookOutput(self.allocator, r.tool_input_json, r.response) catch {
                    try req.respond("{\"ok\":true}", .{ .extra_headers = self.apiHeaders() });
                    return;
                };
                defer self.allocator.free(hook_output);
                try req.respond(hook_output, .{ .extra_headers = self.apiHeaders() });
            } else {
                try req.respond("{\"ok\":true}", .{ .extra_headers = self.apiHeaders() });
            }
        } else {
            try req.respond("{\"ok\":true}", .{ .extra_headers = self.apiHeaders() });
        }
    }

    fn sendSessionsSync(self: *Server, client: *ws_mod.WsClient) void {
        const sessions = self.session_manager.listSessions(self.allocator) catch return;
        defer SessionManager.freeSessionList(self.allocator, sessions);

        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        json_buf.appendSlice(self.allocator, "{\"type\":\"sessions_sync\",\"sessions\":[") catch return;
        for (sessions, 0..) |s, i| {
            if (i > 0) json_buf.appendSlice(self.allocator, ",") catch return;
            self.appendSessionJson(&json_buf, s) catch return;
        }
        json_buf.appendSlice(self.allocator, "]}") catch return;
        client.send(json_buf.items);
    }

    fn handleSessionsApi(self: *Server, req: *http.Server.Request) !void {
        const path = req.head.target;

        if (std.mem.eql(u8, path, "/api/v1/sessions")) {
            const sessions = self.session_manager.listSessions(self.allocator) catch return;
        defer SessionManager.freeSessionList(self.allocator, sessions);

            var json_buf: std.ArrayList(u8) = .empty;
            defer json_buf.deinit(self.allocator);
            try json_buf.appendSlice(self.allocator, "[");
            for (sessions, 0..) |s, i| {
                if (i > 0) try json_buf.appendSlice(self.allocator, ",");
                try self.appendSessionJson(&json_buf, s);
            }
            try json_buf.appendSlice(self.allocator, "]");
            try req.respond(json_buf.items, .{ .extra_headers = self.apiHeaders() });
            return;
        }

        const session_id = parseSessionIdFromPath(path) orelse {
            try req.respond("{\"error\":\"invalid session id\"}", .{
                .status = .bad_request,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };

        if (req.head.method == .DELETE) {
            self.session_manager.destroySession(session_id);
            try req.respond("{\"ok\":true}", .{ .extra_headers = self.apiHeaders() });
            return;
        }

        const session = self.session_manager.getSessionSnapshot(self.allocator, session_id) orelse {
            try req.respond("{\"error\":\"session not found\"}", .{
                .status = .not_found,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };
        defer SessionManager.freeSessionSnapshot(self.allocator, session);

        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);
        try self.appendSessionJson(&json_buf, session);
        try req.respond(json_buf.items, .{ .extra_headers = self.apiHeaders() });
    }

    fn handleTerminalSnapshot(self: *Server, req: *http.Server.Request, path: []const u8) !void {
        const prefix = "/api/v1/sessions/";
        const suffix = "/terminal";
        if (path.len <= prefix.len + suffix.len) {
            try req.respond("{\"error\":\"invalid path\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        }
        const id_str = path[prefix.len .. path.len - suffix.len];
        const session_id = std.fmt.parseInt(u64, id_str, 10) catch {
            try req.respond("{\"error\":\"invalid session id\"}", .{ .status = .bad_request, .extra_headers = self.apiHeaders() });
            return;
        };

        const snapshot = self.session_manager.getTerminalSnapshot(self.allocator, session_id) orelse {
            try req.respond("{\"error\":\"session not found\"}", .{ .status = .not_found, .extra_headers = self.apiHeaders() });
            return;
        };
        defer self.allocator.free(snapshot);

        if (snapshot.len == 0) {
            try req.respond("{\"data\":\"\"}", .{ .extra_headers = self.apiHeaders() });
            return;
        }

        const b64_len = std.base64.standard.Encoder.calcSize(snapshot.len);
        const b64 = try self.allocator.alloc(u8, b64_len);
        defer self.allocator.free(b64);
        const encoded = std.base64.standard.Encoder.encode(b64, snapshot);

        const response = try std.fmt.allocPrint(self.allocator, "{{\"data\":\"{s}\",\"session_id\":{d}}}", .{ encoded, session_id });
        defer self.allocator.free(response);
        try req.respond(response, .{ .extra_headers = self.apiHeaders() });
    }

    fn appendSessionJson(self: *Server, out: *std.ArrayList(u8), s: SessionInfo) !void {
        try out.appendSlice(self.allocator, "{");
        try out.writer(self.allocator).print("\"id\":{d},", .{s.id});
        try protocol.appendJsonStringField(self.allocator, out, "state", stateString(s.state));
        try out.appendSlice(self.allocator, ",");
        try protocol.appendJsonStringField(self.allocator, out, "command", s.command);
        try out.appendSlice(self.allocator, ",");
        try protocol.appendJsonStringField(self.allocator, out, "cwd", s.cwd);

        try out.appendSlice(self.allocator, ",\"tasks\":[");
        for (s.tasks, 0..) |task, i| {
            if (i > 0) try out.appendSlice(self.allocator, ",");
            try out.appendSlice(self.allocator, "{");
            try protocol.appendJsonStringField(self.allocator, out, "id", task.id);
            try out.appendSlice(self.allocator, ",");
            try protocol.appendJsonStringField(self.allocator, out, "subject", task.subject);
            try out.appendSlice(self.allocator, ",\"completed\":");
            try out.appendSlice(self.allocator, if (task.completed) "true" else "false");
            try out.appendSlice(self.allocator, "}");
        }
        try out.appendSlice(self.allocator, "]");

        try out.appendSlice(self.allocator, ",\"subagents\":[");
        for (s.subagents, 0..) |sa, i| {
            if (i > 0) try out.appendSlice(self.allocator, ",");
            try out.appendSlice(self.allocator, "{");
            try protocol.appendJsonStringField(self.allocator, out, "id", sa.id);
            try out.appendSlice(self.allocator, ",");
            try protocol.appendJsonStringField(self.allocator, out, "type", sa.agent_type);
            try out.appendSlice(self.allocator, ",\"completed\":");
            try out.appendSlice(self.allocator, if (sa.completed) "true" else "false");
            try out.appendSlice(self.allocator, ",\"elapsed_ms\":");
            try out.writer(self.allocator).print("{d}", .{sa.elapsed_ms});
            try out.appendSlice(self.allocator, "}");
        }
        try out.appendSlice(self.allocator, "]");

        if (s.current_activity) |act| {
            try out.appendSlice(self.allocator, ",\"activity\":{");
            try protocol.appendJsonStringField(self.allocator, out, "tool_name", act.tool_name);
            try out.appendSlice(self.allocator, "}");
        } else {
            try out.appendSlice(self.allocator, ",\"activity\":null");
        }

        if (s.last_message.len > 0) {
            try out.appendSlice(self.allocator, ",");
            try protocol.appendJsonStringField(self.allocator, out, "last_message", s.last_message);
        } else {
            try out.appendSlice(self.allocator, ",\"last_message\":null");
        }

        if (s.prompt_summary.len > 0 or s.prompt_options.len > 0 or s.prompt_questions.len > 0) {
            try out.appendSlice(self.allocator, ",\"prompt\":{");
            try protocol.appendJsonStringField(self.allocator, out, "summary", s.prompt_summary);
            try out.appendSlice(self.allocator, ",\"options\":[");
            for (s.prompt_options, 0..) |opt, i| {
                if (i > 0) try out.appendSlice(self.allocator, ",");
                try protocol.appendJsonStringValue(self.allocator, out, opt);
            }
            try out.appendSlice(self.allocator, "]");
            if (s.prompt_questions.len > 0) {
                try out.appendSlice(self.allocator, ",\"questions\":[");
                for (s.prompt_questions, 0..) |q, qi| {
                    if (qi > 0) try out.appendSlice(self.allocator, ",");
                    try out.appendSlice(self.allocator, "{");
                    try protocol.appendJsonStringField(self.allocator, out, "question", q.question);
                    try out.appendSlice(self.allocator, ",\"options\":[");
                    for (q.options, 0..) |opt, oi| {
                        if (oi > 0) try out.appendSlice(self.allocator, ",");
                        try protocol.appendJsonStringValue(self.allocator, out, opt);
                    }
                    try out.appendSlice(self.allocator, "]}");
                }
                try out.appendSlice(self.allocator, "]");
            }
            try out.appendSlice(self.allocator, "}");
        } else {
            try out.appendSlice(self.allocator, ",\"prompt\":null");
        }

        try out.appendSlice(self.allocator, "}");
    }

    fn serveStaticFile(self: *Server, req: *http.Server.Request, path: []const u8) !void {
        const dir = self.static_dir orelse {
            try req.respond("{\"error\":\"not found\"}", .{
                .status = .not_found,
                .extra_headers = self.apiHeaders(),
            });
            return;
        };

        const serve_path = if (std.mem.eql(u8, path, "/")) "index.html" else if (path.len > 1) path[1..] else path;

        var path_buf: [1024]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, serve_path }) catch {
            try req.respond("Not Found", .{ .status = .not_found });
            return;
        };

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            var index_buf: [1024]u8 = undefined;
            const index_path = std.fmt.bufPrint(&index_buf, "{s}/index.html", .{dir}) catch {
                try req.respond("Not Found", .{ .status = .not_found });
                return;
            };
            const index_file = std.fs.openFileAbsolute(index_path, .{}) catch {
                try req.respond("Not Found", .{ .status = .not_found });
                return;
            };
            defer index_file.close();

            var buf: [65536]u8 = undefined;
            const n = index_file.readAll(&buf) catch {
                try req.respond("Read Error", .{ .status = .internal_server_error });
                return;
            };
            try req.respond(buf[0..n], .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
            });
            return;
        };
        defer file.close();

        var buf: [65536]u8 = undefined;
        const n = file.readAll(&buf) catch {
            try req.respond("Read Error", .{ .status = .internal_server_error });
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

        try req.respond(buf[0..n], .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = content_type }},
        });
    }

    fn isAuthorized(self: *const Server, req: *const http.Server.Request) bool {
        if (self.auth.disabled) return true;
        const token = self.extractBearerToken(req) orelse return false;
        return self.auth.validateSessionToken(token);
    }

    fn extractBearerToken(_: *const Server, req: *const http.Server.Request) ?[]const u8 {
        var it = req.iterateHeaders();
        while (it.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
            const prefix = "Bearer ";
            if (!std.mem.startsWith(u8, header.value, prefix)) return null;
            return std.mem.trim(u8, header.value[prefix.len..], " ");
        }
        return null;
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }
};

fn stateString(state: @import("session.zig").SessionState) []const u8 {
    return switch (state) {
        .running => "running",
        .waiting => "waiting",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .stopped => "stopped",
    };
}
