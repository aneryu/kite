const std = @import("std");

pub fn encodeTerminalOutput(allocator: std.mem.Allocator, data: []const u8, session_id: u64) ![]u8 {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, data);

    return std.fmt.allocPrint(allocator,
        \\{{"type":"terminal_output","data":"{s}","session_id":{d}}}
    , .{ encoded, session_id });
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

pub fn encodePromptRequest(allocator: std.mem.Allocator, session_id: u64, summary: []const u8, options: []const []const u8, state: @import("session.zig").SessionState) ![]u8 {
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

    const state_str = switch (state) {
        .running => "running",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .waiting_input => "waiting_input",
        .idle => "idle",
        .stopped => "stopped",
    };

    return std.fmt.allocPrint(allocator,
        \\{{"type":"prompt_request","session_id":{d},"state":"{s}","summary":"{s}","options":{s}}}
    , .{ session_id, state_str, escaped_summary, opts_buf.items });
}

pub fn encodeTaskUpdate(allocator: std.mem.Allocator, session_id: u64, task_id: []const u8, subject: []const u8, completed: bool) ![]u8 {
    const escaped_task_id = try jsonEscapeAlloc(allocator, task_id);
    defer allocator.free(escaped_task_id);
    const escaped_subject = try jsonEscapeAlloc(allocator, subject);
    defer allocator.free(escaped_subject);
    return std.fmt.allocPrint(allocator,
        \\{{"type":"task_update","session_id":{d},"task_id":"{s}","subject":"{s}","completed":{s}}}
    , .{ session_id, escaped_task_id, escaped_subject, if (completed) "true" else "false" });
}

pub fn encodeSubagentUpdate(allocator: std.mem.Allocator, session_id: u64, agent_id: []const u8, agent_type: []const u8, description: []const u8, completed: bool, elapsed_ms: i64) ![]u8 {
    const escaped_agent_id = try jsonEscapeAlloc(allocator, agent_id);
    defer allocator.free(escaped_agent_id);
    const escaped_agent_type = try jsonEscapeAlloc(allocator, agent_type);
    defer allocator.free(escaped_agent_type);
    const escaped_description = try jsonEscapeAlloc(allocator, description);
    defer allocator.free(escaped_description);
    return std.fmt.allocPrint(allocator,
        \\{{"type":"subagent_update","session_id":{d},"agent_id":"{s}","agent_type":"{s}","description":"{s}","completed":{s},"elapsed_ms":{d}}}
    , .{ session_id, escaped_agent_id, escaped_agent_type, escaped_description, if (completed) "true" else "false", elapsed_ms });
}

pub const QuestionInfo = @import("session.zig").PromptQuestion;

/// Encode a prompt_request with full questions array (for AskUserQuestion with multiple questions).
pub fn encodeAskPromptRequest(allocator: std.mem.Allocator, session_id: u64, questions: []const QuestionInfo, state: @import("session.zig").SessionState) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const state_str = switch (state) {
        .running => "running",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .waiting_input => "waiting_input",
        .idle => "idle",
        .stopped => "stopped",
    };

    const header = try std.fmt.allocPrint(allocator,
        \\{{"type":"prompt_request","session_id":{d},"state":"{s}","questions":[
    , .{ session_id, state_str });
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (questions, 0..) |q, qi| {
        if (qi > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"question\":\"");
        const eq = try jsonEscapeAlloc(allocator, q.question);
        defer allocator.free(eq);
        try buf.appendSlice(allocator, eq);
        try buf.appendSlice(allocator, "\",\"options\":[");
        for (q.options, 0..) |opt, oi| {
            if (oi > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            const eo = try jsonEscapeAlloc(allocator, opt);
            defer allocator.free(eo);
            try buf.appendSlice(allocator, eo);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "]}");
    }

    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

pub fn encodeActivityUpdate(allocator: std.mem.Allocator, session_id: u64, tool_name: ?[]const u8) ![]u8 {
    if (tool_name) |tn| {
        const escaped_tool_name = try jsonEscapeAlloc(allocator, tn);
        defer allocator.free(escaped_tool_name);
        return std.fmt.allocPrint(allocator,
            \\{{"type":"activity_update","session_id":{d},"tool_name":"{s}"}}
        , .{ session_id, escaped_tool_name });
    } else {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"activity_update","session_id":{d},"tool_name":null}}
        , .{session_id});
    }
}

pub fn encodeSessionStateChange(allocator: std.mem.Allocator, session_id: u64, state: @import("session.zig").SessionState) ![]u8 {
    const state_str = switch (state) {
        .running => "running",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .waiting_input => "waiting_input",
        .idle => "idle",
        .stopped => "stopped",
    };
    return std.fmt.allocPrint(allocator,
        \\{{"type":"session_state_change","session_id":{d},"state":"{s}"}}
    , .{ session_id, state_str });
}

pub fn encodeLastMessageUpdate(allocator: std.mem.Allocator, session_id: u64, message: []const u8) ![]u8 {
    const escaped = try jsonEscapeAlloc(allocator, message);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator,
        \\{{"type":"last_message_update","session_id":{d},"last_message":"{s}"}}
    , .{ session_id, escaped });
}

pub const jsonEscapeAllocPublic = jsonEscapeAlloc;
pub const appendJsonEscapedPublic = appendJsonEscaped;

pub fn appendJsonStringField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(allocator, "\"");
    try out.appendSlice(allocator, key);
    try out.appendSlice(allocator, "\":\"");
    try appendJsonEscaped(out, allocator, value);
    try out.appendSlice(allocator, "\"");
}

pub fn appendJsonStringValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    try out.appendSlice(allocator, "\"");
    try appendJsonEscaped(out, allocator, value);
    try out.appendSlice(allocator, "\"");
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

fn appendJsonEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
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
}

/// Extract the "tool_input":{...} JSON value from a raw hook body.
pub fn extractToolInputJson(allocator: std.mem.Allocator, raw_json: []const u8) []const u8 {
    const key = "\"tool_input\":";
    const idx = std.mem.indexOf(u8, raw_json, key) orelse return "";
    var pos = idx + key.len;
    while (pos < raw_json.len and (raw_json[pos] == ' ' or raw_json[pos] == '\n' or raw_json[pos] == '\r' or raw_json[pos] == '\t')) pos += 1;
    if (pos >= raw_json.len or raw_json[pos] != '{') return "";
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i = pos;
    while (i < raw_json.len) : (i += 1) {
        const ch = raw_json[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (ch == '\\' and in_string) {
            escape = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                return allocator.dupe(u8, raw_json[pos .. i + 1]) catch "";
            }
        }
    }
    return "";
}

/// Build updatedInput JSON: original tool_input with "answers" field injected.
/// answers_json is the raw JSON answers map, e.g. {"Which lesson?":"Option A"}
pub fn buildUpdatedInput(allocator: std.mem.Allocator, tool_input_json: []const u8, answers_json: []const u8) ![]u8 {
    if (tool_input_json.len > 1 and tool_input_json[tool_input_json.len - 1] == '}') {
        return std.fmt.allocPrint(allocator, "{s},\"answers\":{s}}}", .{ tool_input_json[0 .. tool_input_json.len - 1], answers_json });
    }
    return std.fmt.allocPrint(allocator, "{{\"answers\":{s}}}", .{answers_json});
}

/// Build the full PermissionRequest hook output JSON.
/// Format: {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{...}}}}
pub fn buildPermissionHookOutput(allocator: std.mem.Allocator, tool_input_json: []const u8, answers_json: []const u8) ![]u8 {
    const updated_input = try buildUpdatedInput(allocator, tool_input_json, answers_json);
    defer allocator.free(updated_input);
    return std.fmt.allocPrint(allocator,
        \\{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{{"behavior":"allow","updatedInput":{s}}}}}}}
    , .{updated_input});
}

test "encodePromptRequest" {
    const allocator = std.testing.allocator;
    const options = [_][]const u8{ "Yes", "No" };
    const session_mod = @import("session.zig");
    const msg = try encodePromptRequest(allocator, 1, "Continue?", &options, session_mod.SessionState.waiting_input);
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
