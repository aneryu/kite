const std = @import("std");
const protocol = @import("protocol.zig");

pub const HookEventType = enum {
    SessionStart,
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    Notification,
    Stop,
    UserPromptSubmit,
    TaskCreated,
    TaskCompleted,
    SubagentStart,
    SubagentStop,
    PermissionRequest,

    pub fn fromString(s: []const u8) ?HookEventType {
        const map = std.StaticStringMap(HookEventType).initComptime(.{
            .{ "SessionStart", .SessionStart },
            .{ "PreToolUse", .PreToolUse },
            .{ "PostToolUse", .PostToolUse },
            .{ "PostToolUseFailure", .PostToolUseFailure },
            .{ "Notification", .Notification },
            .{ "Stop", .Stop },
            .{ "UserPromptSubmit", .UserPromptSubmit },
            .{ "TaskCreated", .TaskCreated },
            .{ "TaskCompleted", .TaskCompleted },
            .{ "SubagentStart", .SubagentStart },
            .{ "SubagentStop", .SubagentStop },
            .{ "PermissionRequest", .PermissionRequest },
        });
        return map.get(s);
    }

    pub fn toString(self: HookEventType) []const u8 {
        return switch (self) {
            .SessionStart => "SessionStart",
            .PreToolUse => "PreToolUse",
            .PostToolUse => "PostToolUse",
            .PostToolUseFailure => "PostToolUseFailure",
            .Notification => "Notification",
            .Stop => "Stop",
            .UserPromptSubmit => "UserPromptSubmit",
            .TaskCreated => "TaskCreated",
            .TaskCompleted => "TaskCompleted",
            .SubagentStart => "SubagentStart",
            .SubagentStop => "SubagentStop",
            .PermissionRequest => "PermissionRequest",
        };
    }
};

pub const HookInput = struct {
    hook_event_name: []const u8 = "",
    session_id: []const u8 = "",
    tool_name: ?[]const u8 = null,
    tool_input: ?std.json.Value = null,
    notification_message: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
};

pub const HookOutput = struct {
    decision: ?[]const u8 = null, // "block", "approve", or null
    reason: ?[]const u8 = null,
};

pub fn readHookInput(allocator: std.mem.Allocator, reader: anytype) !HookInput {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // Read all of stdin
    while (true) {
        var chunk: [4096]u8 = undefined;
        const n = reader.read(&chunk) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
    }

    if (buf.items.len == 0) return .{};

    const parsed = std.json.parseFromSlice(HookInput, allocator, buf.items, .{
        .ignore_unknown_fields = true,
    }) catch return .{};

    return parsed.value;
}

pub fn writeHookOutput(writer: anytype, output: HookOutput) !void {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeAll("{");
    var first = true;
    if (output.decision) |d| {
        try w.print("\"decision\":\"{s}\"", .{d});
        first = false;
    }
    if (output.reason) |r| {
        if (!first) try w.writeAll(",");
        try w.print("\"reason\":\"{s}\"", .{r});
    }
    try w.writeAll("}");

    try writer.writeAll(fbs.getWritten());
}

pub const ClaudeCodeConfig = struct {
    pub fn generateHooksConfig(allocator: std.mem.Allocator, port: u16) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "hooks": {{
            \\    "PreToolUse": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "PostToolUse": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "PostToolUseFailure": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "TaskCreated": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "TaskCompleted": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "SubagentStart": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "SubagentStop": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "UserPromptSubmit": [{{"hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "Notification": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "Stop": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "SessionStart": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}],
            \\    "PermissionRequest": [{{"matcher": "AskUserQuestion", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}]
            \\  }}
            \\}}
        , .{ port, port, port, port, port, port, port, port, port, port, port, port });
    }
};

pub const IPC_SOCKET_PATH = "/tmp/kite.sock";

pub fn sendHookToServer(allocator: std.mem.Allocator, event_name: []const u8, raw_json: []const u8) !?[]u8 {
    const stream = std.net.connectUnixSocket(IPC_SOCKET_PATH) catch return null;
    defer stream.close();

    // Send: event_name\n<length>\n<json>
    const header = try std.fmt.allocPrint(allocator, "{s}\n{d}\n", .{ event_name, raw_json.len });
    defer allocator.free(header);

    stream.writeAll(header) catch return null;
    stream.writeAll(raw_json) catch return null;

    // For PreToolUse and PermissionRequest, wait for response
    if (std.mem.eql(u8, event_name, "PreToolUse") or std.mem.eql(u8, event_name, "PermissionRequest")) {
        var response_buf: [8192]u8 = undefined;
        var response_total: usize = 0;
        // Read with poll to handle multi-chunk responses
        while (response_total < response_buf.len) {
            var poll_fds = [1]std.posix.pollfd{
                .{ .fd = stream.handle, .events = std.posix.POLL.IN, .revents = 0 },
            };
            // Wait up to 5 minutes for user to answer
            const ready = std.posix.poll(&poll_fds, 300_000) catch break;
            if (ready == 0) break; // timeout
            const n = stream.read(response_buf[response_total..]) catch break;
            if (n == 0) break;
            response_total += n;
            // Check if we have complete JSON (simple heuristic: ends with })
            if (response_total > 0 and response_buf[response_total - 1] == '}') break;
        }
        if (response_total > 0) {
            return try allocator.dupe(u8, response_buf[0..response_total]);
        }
    }

    return null;
}
