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
