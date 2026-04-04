const std = @import("std");
const hooks = @import("hooks.zig");
const prompt_parser = @import("prompt_parser.zig");

pub const HookEventType = hooks.HookEventType;

pub const RingBuffer = struct {
    data: []u8,
    head: usize = 0,
    len: usize = 0,
    allocator: std.mem.Allocator,

    pub const default_capacity = 256 * 1024; // 256KB

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RingBuffer {
        return .{
            .data = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RingBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn write(self: *RingBuffer, bytes: []const u8) void {
        for (bytes) |byte| {
            self.data[(self.head + self.len) % self.data.len] = byte;
            if (self.len == self.data.len) {
                self.head = (self.head + 1) % self.data.len;
            } else {
                self.len += 1;
            }
        }
    }

    pub fn getContents(self: *const RingBuffer, out: []u8) usize {
        const to_copy = @min(self.len, out.len);
        var i: usize = 0;
        while (i < to_copy) : (i += 1) {
            out[i] = self.data[(self.head + i) % self.data.len];
        }
        return to_copy;
    }

    pub fn slice(self: *const RingBuffer) struct { first: []const u8, second: []const u8 } {
        if (self.len == 0) return .{ .first = &.{}, .second = &.{} };
        const start = self.head;
        const end = (self.head + self.len) % self.data.len;
        if (end > start) {
            return .{ .first = self.data[start..end], .second = &.{} };
        } else {
            return .{ .first = self.data[start..], .second = self.data[0..end] };
        }
    }
};

pub const SessionState = enum {
    running,
    asking,
    waiting_permission,
    waiting_input,
    idle,
    stopped,
};

pub const PromptQuestion = struct {
    question: []const u8,
    options: []const []const u8,
};

pub const PromptContext = struct {
    summary: []const u8,
    options: []const []const u8,
    questions: []const PromptQuestion = &.{},
};

pub const TaskInfo = struct {
    id: []const u8,
    subject: []const u8,
    description: []const u8 = "",
    completed: bool = false,
};

pub const SubagentInfo = struct {
    id: []const u8,
    agent_type: []const u8,
    description: []const u8 = "",
    completed: bool = false,
    started_at: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub const ActivityInfo = struct {
    tool_name: []const u8,
    summary: []const u8 = "",
};

pub const Changes = struct {
    state: bool = false,
    prompt: bool = false,
    activity: bool = false,
    last_message: bool = false,
    task: bool = false,
    subagent: bool = false,
    task_idx: ?usize = null,
    subagent_idx: ?usize = null,
};

pub const Session = struct {
    id: u64,
    state: SessionState = .running,
    terminal_buffer: RingBuffer,
    allocator: std.mem.Allocator,
    created_at: i64,
    prompt_context: ?PromptContext = null,
    command: []const u8 = "",
    cwd: []const u8 = "",
    tasks: std.ArrayList(TaskInfo),
    subagents: std.ArrayList(SubagentInfo),
    current_activity: ?ActivityInfo = null,
    last_message: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, id: u64) !Session {
        return .{
            .id = id,
            .terminal_buffer = try RingBuffer.init(allocator, RingBuffer.default_capacity),
            .allocator = allocator,
            .created_at = std.time.timestamp(),
            .tasks = .empty,
            .subagents = .empty,
        };
    }

    pub fn deinit(self: *Session) void {
        self.terminal_buffer.deinit();
        for (self.tasks.items) |task| {
            self.allocator.free(task.id);
            self.allocator.free(task.subject);
            if (task.description.len > 0) self.allocator.free(task.description);
        }
        self.tasks.deinit(self.allocator);
        for (self.subagents.items) |sa| {
            self.allocator.free(sa.id);
            self.allocator.free(sa.agent_type);
            if (sa.description.len > 0) self.allocator.free(sa.description);
        }
        self.subagents.deinit(self.allocator);
        self.freePromptContext();
        self.clearCurrentActivity();
        if (self.last_message.len > 0) self.allocator.free(self.last_message);
    }

    pub fn appendTerminalOutput(self: *Session, data: []const u8) void {
        self.terminal_buffer.write(data);
    }

    /// Clear prompt context (for use by SessionManager.resolvePromptResponse).
    pub fn clearPrompt(self: *Session) void {
        self.freePromptContext();
    }

    /// Process a hook event and update internal state.
    /// Returns flags indicating what changed.
    pub fn applyEvent(self: *Session, event_type: HookEventType, raw_json: []const u8) Changes {
        return switch (event_type) {
            .SessionStart => self.handleSessionStart(),
            .UserPromptSubmit => self.handleUserPromptSubmit(),
            .PreToolUse => self.handlePreToolUse(raw_json),
            .PostToolUse, .PostToolUseFailure => self.handlePostToolUse(),
            .PermissionRequest => self.handlePermissionRequest(raw_json),
            .Stop => self.handleStop(raw_json),
            .Notification => self.handleNotification(raw_json),
            .TaskCreated => self.handleTaskCreated(raw_json),
            .TaskCompleted => self.handleTaskCompleted(raw_json),
            .SubagentStart => self.handleSubagentStart(raw_json),
            .SubagentStop => self.handleSubagentStop(raw_json),
            .SessionEnd => self.handleSessionEnd(),
            else => .{},
        };
    }

    // --- Private event handlers ---

    fn handleSessionStart(self: *Session) Changes {
        self.freePromptContext();
        self.state = .running;
        self.setLastMessage("Session started");
        return .{ .state = true, .prompt = true, .last_message = true };
    }

    fn handleUserPromptSubmit(self: *Session) Changes {
        self.freePromptContext();
        self.state = .running;
        return .{ .state = true, .prompt = true };
    }

    fn handlePreToolUse(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { tool_name: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        const prev_state = self.state;
        self.state = .running;
        self.clearCurrentActivity();
        self.current_activity = .{
            .tool_name = self.allocator.dupe(u8, parsed.value.tool_name) catch return .{},
        };
        self.setLastMessage(parsed.value.tool_name);
        return .{
            .state = prev_state != .running,
            .activity = true,
            .last_message = true,
        };
    }

    fn handlePostToolUse(self: *Session) Changes {
        self.clearCurrentActivity();
        return .{ .activity = true };
    }

    fn handlePermissionRequest(self: *Session, raw_json: []const u8) Changes {
        const ToolNamePayload = struct { tool_name: []const u8 = "" };
        const tn_parsed = std.json.parseFromSlice(ToolNamePayload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer tn_parsed.deinit();

        if (!std.mem.eql(u8, tn_parsed.value.tool_name, "AskUserQuestion")) {
            return .{};
        }

        self.freePromptContext();
        self.state = .asking;

        const AskOption = struct { label: []const u8 = "" };
        const AskQuestion = struct { question: []const u8 = "", options: []const AskOption = &.{} };
        const AskPayload = struct {
            tool_input: ?struct {
                questions: []const AskQuestion = &.{},
            } = null,
        };

        const ask_parsed = std.json.parseFromSlice(AskPayload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return .{ .state = true };

        defer ask_parsed.deinit();

        if (ask_parsed.value.tool_input) |ti| {
            var questions: std.ArrayList(PromptQuestion) = .empty;
            var flat_options: std.ArrayList([]const u8) = .empty;
            var first_question: []const u8 = "";

            for (ti.questions, 0..) |q, qi| {
                if (qi == 0) {
                    first_question = self.allocator.dupe(u8, q.question) catch "";
                }
                var q_opts: std.ArrayList([]const u8) = .empty;
                for (q.options) |opt| {
                    const label = self.allocator.dupe(u8, opt.label) catch continue;
                    q_opts.append(self.allocator, label) catch continue;
                    flat_options.append(self.allocator, self.allocator.dupe(u8, opt.label) catch continue) catch continue;
                }
                questions.append(self.allocator, .{
                    .question = self.allocator.dupe(u8, q.question) catch "",
                    .options = q_opts.toOwnedSlice(self.allocator) catch &.{},
                }) catch continue;
            }

            self.prompt_context = .{
                .summary = first_question,
                .options = flat_options.toOwnedSlice(self.allocator) catch &.{},
                .questions = questions.toOwnedSlice(self.allocator) catch &.{},
            };
        }

        return .{ .state = true, .prompt = true };
    }

    fn handleStop(self: *Session, raw_json: []const u8) Changes {
        const StopPayload = struct { stop_reason: []const u8 = "" };
        const parsed = std.json.parseFromSlice(StopPayload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch {
            self.state = .idle;
            return .{ .state = true };
        };
        defer parsed.deinit();

        self.freePromptContext();

        if (prompt_parser.isWaitingForInput(parsed.value.stop_reason)) {
            const tail = self.getTerminalTail();
            const summary = self.allocator.dupe(u8, prompt_parser.extractSummary(tail)) catch "";
            const extracted_options = prompt_parser.extractOptions(self.allocator, tail) catch &.{};
            defer if (extracted_options.len > 0) self.allocator.free(extracted_options);
            const options = dupStringSlice(self.allocator, extracted_options) catch &.{};
            self.prompt_context = .{
                .summary = summary,
                .options = options,
            };
            self.state = .waiting_input;
            return .{ .state = true, .prompt = true };
        }

        self.state = .idle;
        return .{ .state = true };
    }

    fn handleNotification(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { message: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        if (parsed.value.message.len > 0) {
            self.setLastMessage(parsed.value.message);
            return .{ .last_message = true };
        }
        return .{};
    }

    fn handleTaskCreated(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { task_id: []const u8 = "", task_subject: []const u8 = "", task_description: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        self.tasks.append(self.allocator, .{
            .id = self.allocator.dupe(u8, parsed.value.task_id) catch return .{},
            .subject = self.allocator.dupe(u8, parsed.value.task_subject) catch return .{},
            .description = if (parsed.value.task_description.len > 0) self.allocator.dupe(u8, parsed.value.task_description) catch "" else "",
        }) catch return .{};
        return .{ .task = true, .task_idx = self.tasks.items.len - 1 };
    }

    fn handleTaskCompleted(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { task_id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        for (self.tasks.items, 0..) |*task, idx| {
            if (std.mem.eql(u8, task.id, parsed.value.task_id)) {
                task.completed = true;
                return .{ .task = true, .task_idx = idx };
            }
        }
        return .{};
    }

    fn handleSubagentStart(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { agent_id: []const u8 = "", agent_type: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        self.subagents.append(self.allocator, .{
            .id = self.allocator.dupe(u8, parsed.value.agent_id) catch return .{},
            .agent_type = self.allocator.dupe(u8, parsed.value.agent_type) catch return .{},
            .description = self.allocator.dupe(u8, parsed.value.agent_type) catch "",
            .started_at = std.time.timestamp(),
        }) catch return .{};
        return .{ .subagent = true, .subagent_idx = self.subagents.items.len - 1 };
    }

    fn handleSubagentStop(self: *Session, raw_json: []const u8) Changes {
        const Payload = struct { agent_id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        for (self.subagents.items, 0..) |*sa, idx| {
            if (std.mem.eql(u8, sa.id, parsed.value.agent_id)) {
                sa.completed = true;
                sa.elapsed_ms = (std.time.timestamp() - sa.started_at) * 1000;
                return .{ .subagent = true, .subagent_idx = idx };
            }
        }
        return .{};
    }

    fn handleSessionEnd(self: *Session) Changes {
        self.state = .stopped;
        return .{ .state = true };
    }

    // --- Private helpers ---

    fn freePromptContext(self: *Session) void {
        if (self.prompt_context) |pc| {
            if (pc.summary.len > 0) self.allocator.free(pc.summary);
            for (pc.options) |opt| {
                if (opt.len > 0) self.allocator.free(opt);
            }
            if (pc.options.len > 0) self.allocator.free(pc.options);
            for (pc.questions) |q| {
                if (q.question.len > 0) self.allocator.free(q.question);
                for (q.options) |opt| {
                    if (opt.len > 0) self.allocator.free(opt);
                }
                if (q.options.len > 0) self.allocator.free(q.options);
            }
            if (pc.questions.len > 0) self.allocator.free(pc.questions);
            self.prompt_context = null;
        }
    }

    fn clearCurrentActivity(self: *Session) void {
        if (self.current_activity) |act| {
            self.allocator.free(act.tool_name);
            if (act.summary.len > 0) self.allocator.free(act.summary);
        }
        self.current_activity = null;
    }

    fn setLastMessage(self: *Session, msg: []const u8) void {
        if (self.last_message.len > 0) self.allocator.free(self.last_message);
        self.last_message = self.allocator.dupe(u8, msg) catch "";
    }

    fn getTerminalTail(self: *Session) []const u8 {
        const sl = self.terminal_buffer.slice();
        if (sl.second.len > 0) return sl.second;
        return sl.first;
    }
};

fn dupStringSlice(allocator: std.mem.Allocator, input: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    for (input) |item| {
        try out.append(allocator, try allocator.dupe(u8, item));
    }
    return out.toOwnedSlice(allocator);
}

// === Tests ===

test "ring buffer" {
    const allocator = std.testing.allocator;
    var rb = try RingBuffer.init(allocator, 8);
    defer rb.deinit();

    rb.write("hello");
    var out: [16]u8 = undefined;
    const n = rb.getContents(&out);
    try std.testing.expectEqualStrings("hello", out[0..n]);

    // Overflow test
    rb.write("world!!!");
    const n2 = rb.getContents(&out);
    try std.testing.expectEqual(@as(usize, 8), n2);
}

test "session init state is running" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    try std.testing.expectEqual(SessionState.running, s.state);
}

test "SessionStart sets running and last_message" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .idle;
    const changes = s.applyEvent(.SessionStart, "{}");
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(changes.state);
    try std.testing.expect(changes.last_message);
    try std.testing.expectEqualStrings("Session started", s.last_message);
}

test "UserPromptSubmit sets running and clears prompt" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .idle;
    const changes = s.applyEvent(.UserPromptSubmit, "{}");
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(changes.state);
    try std.testing.expect(s.prompt_context == null);
}

test "PreToolUse sets activity" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.PreToolUse,
        \\{"tool_name":"Bash"}
    );
    try std.testing.expect(changes.activity);
    try std.testing.expect(changes.last_message);
    try std.testing.expectEqualStrings("Bash", s.current_activity.?.tool_name);
    try std.testing.expectEqual(SessionState.running, s.state);
}

test "PostToolUse clears activity without changing state" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .running;
    _ = s.applyEvent(.PreToolUse,
        \\{"tool_name":"Read"}
    );
    const changes = s.applyEvent(.PostToolUse, "{}");
    try std.testing.expect(changes.activity);
    try std.testing.expect(!changes.state);
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(s.current_activity == null);
}

test "Stop sets idle" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .running;
    const changes = s.applyEvent(.Stop,
        \\{"stop_reason":"error"}
    );
    try std.testing.expect(changes.state);
    try std.testing.expectEqual(SessionState.idle, s.state);
}

test "Notification sets last_message" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.Notification,
        \\{"message":"Claude needs attention"}
    );
    try std.testing.expect(changes.last_message);
    try std.testing.expect(!changes.state);
    try std.testing.expectEqualStrings("Claude needs attention", s.last_message);
}

test "TaskCreated appends task" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.TaskCreated,
        \\{"task_id":"t1","task_subject":"Fix bug"}
    );
    try std.testing.expect(changes.task);
    try std.testing.expectEqual(@as(usize, 1), s.tasks.items.len);
    try std.testing.expectEqualStrings("t1", s.tasks.items[0].id);
    try std.testing.expectEqualStrings("Fix bug", s.tasks.items[0].subject);
}

test "TaskCompleted marks task done" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    _ = s.applyEvent(.TaskCreated,
        \\{"task_id":"t1","task_subject":"Fix bug"}
    );
    const changes = s.applyEvent(.TaskCompleted,
        \\{"task_id":"t1"}
    );
    try std.testing.expect(changes.task);
    try std.testing.expect(s.tasks.items[0].completed);
}

test "SubagentStart appends subagent" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.SubagentStart,
        \\{"agent_id":"sa1","agent_type":"Explore"}
    );
    try std.testing.expect(changes.subagent);
    try std.testing.expectEqual(@as(usize, 1), s.subagents.items.len);
    try std.testing.expectEqualStrings("sa1", s.subagents.items[0].id);
    try std.testing.expectEqualStrings("Explore", s.subagents.items[0].agent_type);
}

test "SubagentStop marks completed" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    _ = s.applyEvent(.SubagentStart,
        \\{"agent_id":"sa1","agent_type":"Explore"}
    );
    const changes = s.applyEvent(.SubagentStop,
        \\{"agent_id":"sa1"}
    );
    try std.testing.expect(changes.subagent);
    try std.testing.expect(s.subagents.items[0].completed);
}

test "SessionEnd sets stopped" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.SessionEnd, "{}");
    try std.testing.expect(changes.state);
    try std.testing.expectEqual(SessionState.stopped, s.state);
}

test "unknown event returns no changes" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.FileChanged, "{}");
    try std.testing.expect(!changes.state);
    try std.testing.expect(!changes.prompt);
    try std.testing.expect(!changes.activity);
}
