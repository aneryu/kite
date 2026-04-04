const std = @import("std");

pub fn encodeTerminalOutput(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, data);

    return std.fmt.allocPrint(allocator,
        \\{{"type":"terminal_output","data":"{s}"}}
    , .{encoded});
}

pub fn encodeHookEvent(allocator: std.mem.Allocator, event_name: []const u8, tool_name: []const u8, raw_json: []const u8) ![]u8 {
    const escaped_detail = try jsonEscapeAlloc(allocator, raw_json);
    defer allocator.free(escaped_detail);

    return std.fmt.allocPrint(allocator,
        \\{{"type":"hook_event","event":"{s}","tool":"{s}","detail":"{s}","ts":{d}}}
    , .{ event_name, tool_name, escaped_detail, std.time.timestamp() });
}

pub fn encodeSessionStatus(allocator: std.mem.Allocator, state: []const u8, session_id: u64) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"type":"session_status","state":"{s}","session_id":{d}}}
    , .{ state, session_id });
}

pub fn encodeApprovalRequest(allocator: std.mem.Allocator, request_id: []const u8, tool_name: []const u8, tool_input: []const u8) ![]u8 {
    const escaped = try jsonEscapeAlloc(allocator, tool_input);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator,
        \\{{"type":"approval_request","request_id":"{s}","tool":"{s}","input":"{s}"}}
    , .{ request_id, tool_name, escaped });
}

pub fn encodeAuthResult(allocator: std.mem.Allocator, success: bool, token: []const u8) ![]u8 {
    if (success) {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"auth_result","success":true,"token":"{s}"}}
        , .{token});
    } else {
        return allocator.dupe(u8, "{\"type\":\"auth_result\",\"success\":false}");
    }
}

pub const ClientMessage = struct {
    @"type": []const u8,
    data: ?[]const u8 = null,
    token: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    request_id: ?[]const u8 = null,
    approved: ?bool = null,
    session_id: ?u64 = null,
    text: ?[]const u8 = null, // prompt_response 的用户输入文本
};

pub const ParsedClientMessage = struct {
    inner: std.json.Parsed(ClientMessage),

    pub fn value(self: *const ParsedClientMessage) ClientMessage {
        return self.inner.value;
    }

    pub fn deinit(self: *ParsedClientMessage) void {
        self.inner.deinit();
    }
};

pub fn parseClientMessage(allocator: std.mem.Allocator, raw: []const u8) !ParsedClientMessage {
    const parsed = try std.json.parseFromSlice(ClientMessage, allocator, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    return .{ .inner = parsed };
}

pub fn encodePromptRequest(allocator: std.mem.Allocator, session_id: u64, summary: []const u8, options: []const []const u8) ![]u8 {
    const escaped_summary = try jsonEscapeAlloc(allocator, summary);
    defer allocator.free(escaped_summary);

    var opts_buf: std.ArrayList(u8) = .empty;
    defer opts_buf.deinit(allocator);
    try opts_buf.append(allocator, '[');
    for (options, 0..) |opt, i| {
        if (i > 0) try opts_buf.append(allocator, ',');
        try opts_buf.append(allocator, '"');
        const escaped_opt = try jsonEscapeAlloc(allocator, opt);
        defer allocator.free(escaped_opt);
        try opts_buf.appendSlice(allocator, escaped_opt);
        try opts_buf.append(allocator, '"');
    }
    try opts_buf.append(allocator, ']');

    return std.fmt.allocPrint(allocator,
        \\{{"type":"prompt_request","session_id":{d},"summary":"{s}","options":{s}}}
    , .{ session_id, escaped_summary, opts_buf.items });
}

pub fn encodeSessionStateChange(allocator: std.mem.Allocator, session_id: u64, state: @import("session.zig").SessionState) ![]u8 {
    const state_str = switch (state) {
        .starting => "starting",
        .running => "running",
        .waiting_input => "waiting_input",
        .stopped => "stopped",
    };
    return std.fmt.allocPrint(allocator,
        \\{{"type":"session_state_change","session_id":{d},"state":"{s}"}}
    , .{ session_id, state_str });
}

fn jsonEscapeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue;
                    try out.appendSlice(allocator, hex);
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

test "encodePromptRequest" {
    const allocator = std.testing.allocator;
    const options = [_][]const u8{ "Yes", "No" };
    const msg = try encodePromptRequest(allocator, 1, "Continue?", &options);
    defer allocator.free(msg);
    const parsed = try std.json.parseFromSlice(struct {
        @"type": []const u8,
        session_id: u64,
        summary: []const u8,
    }, allocator, msg, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("prompt_request", parsed.value.@"type");
    try std.testing.expectEqual(@as(u64, 1), parsed.value.session_id);
}

test "encodeSessionStateChange" {
    const allocator = std.testing.allocator;
    const session_mod = @import("session.zig");
    const msg = try encodeSessionStateChange(allocator, 1, session_mod.SessionState.waiting_input);
    defer allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "waiting_input") != null);
}
