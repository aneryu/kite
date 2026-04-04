# Session Layer Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Session into a self-contained state machine, expand HookEventType to 26 variants, simplify SessionState, remove hook event history storage, and fix two existing bugs (P1/P2).

**Architecture:** Session owns all state transitions via `applyEvent()` returning change flags. SessionManager becomes a thin orchestrator: lock, call applyEvent, encode protocol messages based on flags, unlock, broadcast. Hook event history is removed from Session — events are transient inputs.

**Tech Stack:** Zig 0.15.2 (backend), Svelte 5 + TypeScript (frontend)

**Spec:** `docs/superpowers/specs/2026-04-04-session-refactor-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `src/hooks.zig` | Modify | Expand HookEventType enum to 26 variants |
| `src/session.zig` | Rewrite | State machine with applyEvent(), Changes, new SessionState; remove HookEvent/hook_events |
| `src/session_manager.zig` | Modify | Slim handleHookEvent to use applyEvent+Changes; remove event history APIs; fix P1/P2 |
| `src/protocol.zig` | Modify | Update SessionState switches, remove encodeHookEvent, add description to subagent |
| `src/http.zig` | Modify | Remove events API endpoint, update stateString, remove encodeHookEvent call |
| `src/main.zig` | Modify | Remove encodeHookEvent call from IPC handler |
| `web/src/lib/types.ts` | Modify | Update SessionState type, add description to SubagentInfo |
| `web/src/stores/sessions.ts` | Modify | Update sort priority map |
| `web/src/components/SessionCard.svelte` | Modify | Remove starting CSS, add waiting_permission |
| `web/src/components/SessionDetail.svelte` | Modify | Remove starting CSS, add waiting_permission |

---

### Task 1: Expand HookEventType to 26 variants (hooks.zig)

**Files:**
- Modify: `src/hooks.zig:4-52`

- [ ] **Step 1: Write test for new event types**

Add at end of `src/hooks.zig`:

```zig
test "HookEventType fromString covers all 26 events" {
    const expected = [_]struct { str: []const u8, val: HookEventType }{
        .{ .str = "SessionStart", .val = .SessionStart },
        .{ .str = "InstructionsLoaded", .val = .InstructionsLoaded },
        .{ .str = "UserPromptSubmit", .val = .UserPromptSubmit },
        .{ .str = "PreToolUse", .val = .PreToolUse },
        .{ .str = "PermissionRequest", .val = .PermissionRequest },
        .{ .str = "PermissionDenied", .val = .PermissionDenied },
        .{ .str = "PostToolUse", .val = .PostToolUse },
        .{ .str = "PostToolUseFailure", .val = .PostToolUseFailure },
        .{ .str = "Notification", .val = .Notification },
        .{ .str = "SubagentStart", .val = .SubagentStart },
        .{ .str = "SubagentStop", .val = .SubagentStop },
        .{ .str = "TaskCreated", .val = .TaskCreated },
        .{ .str = "TaskCompleted", .val = .TaskCompleted },
        .{ .str = "Stop", .val = .Stop },
        .{ .str = "StopFailure", .val = .StopFailure },
        .{ .str = "TeammateIdle", .val = .TeammateIdle },
        .{ .str = "CwdChanged", .val = .CwdChanged },
        .{ .str = "FileChanged", .val = .FileChanged },
        .{ .str = "ConfigChange", .val = .ConfigChange },
        .{ .str = "WorktreeCreate", .val = .WorktreeCreate },
        .{ .str = "WorktreeRemove", .val = .WorktreeRemove },
        .{ .str = "PreCompact", .val = .PreCompact },
        .{ .str = "PostCompact", .val = .PostCompact },
        .{ .str = "Elicitation", .val = .Elicitation },
        .{ .str = "ElicitationResult", .val = .ElicitationResult },
        .{ .str = "SessionEnd", .val = .SessionEnd },
    };
    for (expected) |e| {
        const result = HookEventType.fromString(e.str);
        try std.testing.expect(result != null);
        try std.testing.expectEqual(e.val, result.?);
        try std.testing.expectEqualStrings(e.str, result.?.toString());
    }
    // Unknown string returns null
    try std.testing.expect(HookEventType.fromString("Bogus") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "HookEventType fromString"`
Expected: FAIL — `InstructionsLoaded` etc. not found in enum.

- [ ] **Step 3: Expand the enum, fromString, and toString**

Replace the entire `HookEventType` enum in `src/hooks.zig:4-52` with:

```zig
pub const HookEventType = enum {
    SessionStart,
    InstructionsLoaded,
    UserPromptSubmit,
    PreToolUse,
    PermissionRequest,
    PermissionDenied,
    PostToolUse,
    PostToolUseFailure,
    Notification,
    SubagentStart,
    SubagentStop,
    TaskCreated,
    TaskCompleted,
    Stop,
    StopFailure,
    TeammateIdle,
    CwdChanged,
    FileChanged,
    ConfigChange,
    WorktreeCreate,
    WorktreeRemove,
    PreCompact,
    PostCompact,
    Elicitation,
    ElicitationResult,
    SessionEnd,

    pub fn fromString(s: []const u8) ?HookEventType {
        const map = std.StaticStringMap(HookEventType).initComptime(.{
            .{ "SessionStart", .SessionStart },
            .{ "InstructionsLoaded", .InstructionsLoaded },
            .{ "UserPromptSubmit", .UserPromptSubmit },
            .{ "PreToolUse", .PreToolUse },
            .{ "PermissionRequest", .PermissionRequest },
            .{ "PermissionDenied", .PermissionDenied },
            .{ "PostToolUse", .PostToolUse },
            .{ "PostToolUseFailure", .PostToolUseFailure },
            .{ "Notification", .Notification },
            .{ "SubagentStart", .SubagentStart },
            .{ "SubagentStop", .SubagentStop },
            .{ "TaskCreated", .TaskCreated },
            .{ "TaskCompleted", .TaskCompleted },
            .{ "Stop", .Stop },
            .{ "StopFailure", .StopFailure },
            .{ "TeammateIdle", .TeammateIdle },
            .{ "CwdChanged", .CwdChanged },
            .{ "FileChanged", .FileChanged },
            .{ "ConfigChange", .ConfigChange },
            .{ "WorktreeCreate", .WorktreeCreate },
            .{ "WorktreeRemove", .WorktreeRemove },
            .{ "PreCompact", .PreCompact },
            .{ "PostCompact", .PostCompact },
            .{ "Elicitation", .Elicitation },
            .{ "ElicitationResult", .ElicitationResult },
            .{ "SessionEnd", .SessionEnd },
        });
        return map.get(s);
    }

    pub fn toString(self: HookEventType) []const u8 {
        return switch (self) {
            .SessionStart => "SessionStart",
            .InstructionsLoaded => "InstructionsLoaded",
            .UserPromptSubmit => "UserPromptSubmit",
            .PreToolUse => "PreToolUse",
            .PermissionRequest => "PermissionRequest",
            .PermissionDenied => "PermissionDenied",
            .PostToolUse => "PostToolUse",
            .PostToolUseFailure => "PostToolUseFailure",
            .Notification => "Notification",
            .SubagentStart => "SubagentStart",
            .SubagentStop => "SubagentStop",
            .TaskCreated => "TaskCreated",
            .TaskCompleted => "TaskCompleted",
            .Stop => "Stop",
            .StopFailure => "StopFailure",
            .TeammateIdle => "TeammateIdle",
            .CwdChanged => "CwdChanged",
            .FileChanged => "FileChanged",
            .ConfigChange => "ConfigChange",
            .WorktreeCreate => "WorktreeCreate",
            .WorktreeRemove => "WorktreeRemove",
            .PreCompact => "PreCompact",
            .PostCompact => "PostCompact",
            .Elicitation => "Elicitation",
            .ElicitationResult => "ElicitationResult",
            .SessionEnd => "SessionEnd",
        };
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "hooks|FAIL"`
Expected: All hooks tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/hooks.zig
git commit -m "refactor: expand HookEventType to 26 variants per Claude Code docs"
```

---

### Task 2: Rewrite session.zig — new SessionState, remove HookEvent, add applyEvent

This is the core task. We rewrite `src/session.zig` to:
- New `SessionState` enum (remove `starting`, add `waiting_permission`)
- Remove `HookEvent` struct, `hook_events` field, `addHookEvent` method
- Remove `setWaitingInput` / `clearPromptContext` public methods
- Add `Changes` packed struct
- Add `applyEvent` method and all `handle*` private methods
- Add `freePromptContext`, `clearCurrentActivity`, `setLastMessage` private helpers
- Add `SubagentInfo.description` field

**Files:**
- Rewrite: `src/session.zig`

- [ ] **Step 1: Write failing tests for the new state machine**

Replace the existing tests at the bottom of `src/session.zig` (lines 179-213) with these new tests. Keep RingBuffer tests unchanged.

```zig
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
    // First set an activity
    _ = s.applyEvent(.PreToolUse,
        \\{"tool_name":"Read"}
    );
    const changes = s.applyEvent(.PostToolUse, "{}");
    try std.testing.expect(changes.activity);
    try std.testing.expect(!changes.state);
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(s.current_activity == null);
}

test "Stop with end_turn sets idle" {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -c FAIL`
Expected: Multiple failures (applyEvent doesn't exist yet, SessionState.starting referenced in old tests).

- [ ] **Step 3: Rewrite session.zig**

Replace the entire content of `src/session.zig` with:

```zig
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
```

- [ ] **Step 4: Run all tests**

Run: `zig build test 2>&1 | tail -5`
Expected: session.zig tests pass. Other files (protocol.zig, session_manager.zig, http.zig) may have compile errors due to removed types — that's expected, we fix them in subsequent tasks.

- [ ] **Step 5: Commit**

```bash
git add src/session.zig
git commit -m "refactor: rewrite session.zig as self-contained state machine with applyEvent"
```

---

### Task 3: Update protocol.zig — remove encodeHookEvent, update SessionState switches

**Files:**
- Modify: `src/protocol.zig:14-25` (delete encodeHookEvent)
- Modify: `src/protocol.zig:101-108`, `142-149`, `194-201` (SessionState switches — remove `starting`, add `waiting_permission`)
- Modify: `src/protocol.zig:125-133` (encodeSubagentUpdate — add description)

- [ ] **Step 1: Delete `encodeHookEvent` function**

Remove `src/protocol.zig` lines 14-25 (the entire `encodeHookEvent` function).

- [ ] **Step 2: Update all SessionState switch statements**

In `encodePromptRequest` (around line 101), `encodeAskPromptRequest` (around line 142), and `encodeSessionStateChange` (around line 194), replace each SessionState switch:

**Before (each occurrence):**
```zig
    const state_str = switch (state) {
        .starting => "starting",
        .running => "running",
        .idle => "idle",
        .waiting_input => "waiting_input",
        .asking => "asking",
        .stopped => "stopped",
    };
```

**After (each occurrence):**
```zig
    const state_str = switch (state) {
        .running => "running",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .waiting_input => "waiting_input",
        .idle => "idle",
        .stopped => "stopped",
    };
```

- [ ] **Step 3: Add description to `encodeSubagentUpdate`**

Replace the `encodeSubagentUpdate` function with:

```zig
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
```

- [ ] **Step 4: Update QuestionInfo import**

Change line 135 from:
```zig
pub const QuestionInfo = @import("session.zig").PromptQuestion;
```
No change needed here — the type still exists in session.zig.

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | grep -E "protocol|FAIL"`
Expected: protocol tests pass. The `encodePromptRequest` test still works.

- [ ] **Step 6: Commit**

```bash
git add src/protocol.zig
git commit -m "refactor: update protocol.zig for new SessionState, remove encodeHookEvent"
```

---

### Task 4: Slim down session_manager.zig — use applyEvent, fix P1/P2

**Files:**
- Modify: `src/session_manager.zig`

This is the largest modification. We:
1. Replace the entire `handleHookEvent` body with applyEvent + Changes-based message encoding
2. Remove `freePromptContextLocked`, `clearCurrentActivityLocked`, `setLastMessageLocked`, `appendHookEventLocked`
3. Remove `getSessionEvents`, `freeSessionEvents`, `HookEventInfo`, `tryAppendHookEvent`
4. Fix P1 (PendingAsk use-after-free in deinit)
5. Fix P2 (asking → running, not idle, in resolvePromptResponse)
6. Remove `getTerminalTail`, `StopPayload` (moved to session.zig)
7. Update `dupSessionInfo` / `freeSessionInfo` for removed hook_events and added description
8. Update `dupSubagents` for description field

- [ ] **Step 1: Fix P2 — resolvePromptResponse state transition**

In `resolvePromptResponse` (around line 636-639), change:

**Before:**
```zig
        if (ms.session.state == .asking) {
            should_resolve_pending = true;
            next_state = .idle;
```

**After:**
```zig
        if (ms.session.state == .asking) {
            should_resolve_pending = true;
            next_state = .running;
```

- [ ] **Step 2: Fix P1 — PendingAsk use-after-free in deinit**

Replace the `deinit` method's pending_asks cleanup (around lines 100-113) with:

**Before:**
```zig
        self.mutex.lock();
        var pa_it = self.pending_asks.valueIterator();
        while (pa_it.next()) |pa_ptr| {
            pa_ptr.*.mutex.lock();
            if (pa_ptr.*.response == null) {
                pa_ptr.*.response = self.allocator.dupe(u8, "{}") catch "";
            }
            pa_ptr.*.cond.signal();
            pa_ptr.*.mutex.unlock();
            self.allocator.destroy(pa_ptr.*);
        }
        self.pending_asks.deinit();
        self.mutex.unlock();
```

**After:**
```zig
        // Signal all pending asks so waiters wake up and clean up themselves.
        // Do NOT destroy PendingAsk here — the waiter thread owns destruction
        // via waitPendingAsk() which calls allocator.destroy(pa) after reading.
        self.mutex.lock();
        var pa_it = self.pending_asks.valueIterator();
        while (pa_it.next()) |pa_ptr| {
            pa_ptr.*.mutex.lock();
            if (pa_ptr.*.response == null) {
                pa_ptr.*.response = self.allocator.dupe(u8, "{}") catch "";
            }
            pa_ptr.*.cond.signal();
            pa_ptr.*.mutex.unlock();
        }
        self.pending_asks.deinit();
        self.mutex.unlock();
```

- [ ] **Step 3: Replace handleHookEvent with applyEvent-based implementation**

Replace the entire `handleHookEvent` method (around lines 376-621) with:

```zig
    pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
        const hooks = @import("hooks.zig");
        const event_type = hooks.HookEventType.fromString(event_name) orelse return;

        var msgs: [6]?[]const u8 = .{null} ** 6;
        defer for (&msgs) |*m| if (m.*) |msg| self.allocator.free(msg);

        self.mutex.lock();
        const ms = self.sessions.get(session_id) orelse {
            self.mutex.unlock();
            return;
        };
        const session = &ms.session;

        const changes = session.applyEvent(event_type, raw_json);

        if (changes.state)
            msgs[0] = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch null;
        if (changes.prompt) {
            if (session.state == .asking) {
                if (session.prompt_context) |pc| {
                    msgs[1] = protocol.encodeAskPromptRequest(self.allocator, session.id, pc.questions, session.state) catch null;
                }
            } else if (session.prompt_context) |pc| {
                msgs[1] = protocol.encodePromptRequest(self.allocator, session.id, pc.summary, pc.options, session.state) catch null;
            }
        }
        if (changes.activity)
            msgs[2] = protocol.encodeActivityUpdate(self.allocator, session.id, if (session.current_activity) |act| act.tool_name else null) catch null;
        if (changes.last_message)
            msgs[3] = protocol.encodeLastMessageUpdate(self.allocator, session.id, session.last_message) catch null;
        if (changes.task) {
            if (changes.task_idx) |idx| {
                const task = session.tasks.items[idx];
                msgs[4] = protocol.encodeTaskUpdate(self.allocator, session.id, task.id, task.subject, task.completed) catch null;
            }
        }
        if (changes.subagent) {
            if (changes.subagent_idx) |idx| {
                const sa = session.subagents.items[idx];
                msgs[5] = protocol.encodeSubagentUpdate(self.allocator, session.id, sa.id, sa.agent_type, sa.description, sa.completed, sa.elapsed_ms) catch null;
            }
        }
        self.mutex.unlock();

        for (msgs) |msg| if (msg) |m| self.broadcaster.broadcast(m);
    }
```

- [ ] **Step 4: Remove dead code from SessionManager**

Delete the following functions/types that are no longer used:

1. `HookEventInfo` struct (around line 24-29)
2. `getSessionEvents` method (around lines 297-316)
3. `freeSessionEvents` method (around lines 318-324)
4. `appendHookEventLocked` method (around lines 677-691)
5. `freePromptContextLocked` method (around lines 721-738)
6. `clearCurrentActivityLocked` method (around lines 745-751)
7. `setLastMessageLocked` method (around lines 740-743)
8. `tryAppendHookEvent` function (around lines 835-841)
9. `getTerminalTail` function (around lines 916-920)
10. `StopPayload` struct (around lines 922-924)

- [ ] **Step 5: Update `freePromptContextLocked` call in `resolvePromptResponse`**

In `resolvePromptResponse` (around line 647), replace:
```zig
        self.freePromptContextLocked(&ms.session);
        ms.session.clearPromptContext();
```
With:
```zig
        ms.session.freePromptContext();
```

Wait — `freePromptContext` is private in Session. We need to make it pub or add a public `clearPrompt` method. Add to Session:

Actually, `resolvePromptResponse` needs to clear the prompt from outside. Add a simple pub method to Session in `src/session.zig`:

```zig
    pub fn clearPrompt(self: *Session) void {
        self.freePromptContext();
    }
```

Then in `resolvePromptResponse`, replace:
```zig
        self.freePromptContextLocked(&ms.session);
        ms.session.clearPromptContext();
```
With:
```zig
        ms.session.clearPrompt();
```

- [ ] **Step 6: Update dupSubagents for description field**

In the `dupSubagents` function (around line 895), add `.description`:

**Before:**
```zig
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, sa.id),
            .agent_type = try allocator.dupe(u8, sa.agent_type),
            .completed = sa.completed,
            .started_at = sa.started_at,
            .elapsed_ms = sa.elapsed_ms,
        });
```

**After:**
```zig
        try out.append(allocator, .{
            .id = try allocator.dupe(u8, sa.id),
            .agent_type = try allocator.dupe(u8, sa.agent_type),
            .description = if (sa.description.len > 0) try allocator.dupe(u8, sa.description) else "",
            .completed = sa.completed,
            .started_at = sa.started_at,
            .elapsed_ms = sa.elapsed_ms,
        });
```

Update `freeSessionInfo` to free description:

In `freeSessionInfo` (around line 814), add after `allocator.free(sa.agent_type);`:
```zig
        if (sa.description.len > 0) allocator.free(sa.description);
```

- [ ] **Step 7: Update createSession — initial state is .running**

In `createSession` (around line 196), remove or change:
```zig
        ms.session.state = .starting;
```
to:
```zig
        // Session.init already sets state = .running
```
(Just delete the line — Session.init defaults to `.running`.)

And after `try ms.pty.spawnCwd(...)`, remove:
```zig
        ms.session.state = .running;
```
(Also delete — already `.running`.)

- [ ] **Step 8: Run all tests**

Run: `zig build test 2>&1 | tail -10`
Expected: session_manager tests pass. May still have compile errors in http.zig and main.zig.

- [ ] **Step 9: Commit**

```bash
git add src/session.zig src/session_manager.zig
git commit -m "refactor: slim session_manager to use applyEvent, fix P1/P2 bugs"
```

---

### Task 5: Update http.zig — remove events API, remove encodeHookEvent, update stateString

**Files:**
- Modify: `src/http.zig`

- [ ] **Step 1: Remove `HookEventInfo` import**

Delete line 10:
```zig
const HookEventInfo = session_manager_mod.HookEventInfo;
```

- [ ] **Step 2: Remove `encodeHookEvent` call from hook handler**

In the HTTP hook handler (around lines 336-340), remove:
```zig
        const msg = protocol.encodeHookEvent(self.allocator, event_name, tool_name, body_slice, session_id) catch null;
        if (msg) |m| {
            defer self.allocator.free(m);
            self.broadcaster.broadcast(m);
        }
```

The `handleHookEvent` in SessionManager now handles all broadcasting.

- [ ] **Step 3: Remove session events endpoint handler**

Delete the entire `handleSessionEvents` function (around lines 425-461) and remove its routing entry. Find where it's called in the routing logic and remove that `if` branch.

- [ ] **Step 4: Update `stateString` function**

Replace the `stateString` function at the bottom of http.zig (around lines 672-681) with:

```zig
fn stateString(state: @import("session.zig").SessionState) []const u8 {
    return switch (state) {
        .running => "running",
        .asking => "asking",
        .waiting_permission => "waiting_permission",
        .waiting_input => "waiting_input",
        .idle => "idle",
        .stopped => "stopped",
    };
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: http.zig compiles. May still have main.zig errors.

- [ ] **Step 6: Commit**

```bash
git add src/http.zig
git commit -m "refactor: remove events API and encodeHookEvent from http handler"
```

---

### Task 6: Update main.zig — remove encodeHookEvent call

**Files:**
- Modify: `src/main.zig:486-488`

- [ ] **Step 1: Remove encodeHookEvent broadcast from IPC handler**

In `handleIpcConnection` (around lines 486-488), remove:
```zig
    const msg = protocol.encodeHookEvent(allocator, event_name, tool_name, rest, session_id) catch return false;
    defer allocator.free(msg);
    broadcaster.broadcast(msg);
```

The `handleHookEvent` call on line 490 now handles all broadcasting via the Changes-based system.

- [ ] **Step 2: Build and run all tests**

Run: `zig build test 2>&1 | tail -10`
Expected: All tests pass. Full build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "refactor: remove encodeHookEvent from IPC handler"
```

---

### Task 7: Update frontend types

**Files:**
- Modify: `web/src/lib/types.ts`
- Modify: `web/src/stores/sessions.ts`
- Modify: `web/src/components/SessionCard.svelte`
- Modify: `web/src/components/SessionDetail.svelte`

- [ ] **Step 1: Update SessionInfo state type and SubagentInfo**

In `web/src/lib/types.ts`, change line 31:

**Before:**
```typescript
  state: 'starting' | 'running' | 'idle' | 'waiting_input' | 'asking' | 'stopped';
```

**After:**
```typescript
  state: 'running' | 'asking' | 'waiting_permission' | 'waiting_input' | 'idle' | 'stopped';
```

Add `description` to `SubagentInfo` (around line 9):

**Before:**
```typescript
export interface SubagentInfo {
  id: string;
  type: string;
  completed: boolean;
  elapsed_ms: number;
}
```

**After:**
```typescript
export interface SubagentInfo {
  id: string;
  type: string;
  description: string;
  completed: boolean;
  elapsed_ms: number;
}
```

- [ ] **Step 2: Update sort priority in sessions store**

In `web/src/stores/sessions.ts` (around line 134), change:

**Before:**
```typescript
    const priority: Record<string, number> = { asking: 0, waiting_input: 0, running: 1, idle: 2, starting: 3 };
```

**After:**
```typescript
    const priority: Record<string, number> = { asking: 0, waiting_input: 0, waiting_permission: 0, running: 1, idle: 2 };
```

- [ ] **Step 3: Update SessionCard.svelte CSS**

In `web/src/components/SessionCard.svelte` (around line 200), replace:
```css
  .status.starting { background: var(--accent); color: #000; }
```
With:
```css
  .status.waiting_permission { background: var(--warning, #f59e0b); color: #000; }
```

- [ ] **Step 4: Update SessionDetail.svelte CSS**

In `web/src/components/SessionDetail.svelte` (around line 61), replace:
```css
  .status.starting { background: var(--accent); color: #000; }
```
With:
```css
  .status.waiting_permission { background: var(--warning, #f59e0b); color: #000; }
```

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/types.ts web/src/stores/sessions.ts web/src/components/SessionCard.svelte web/src/components/SessionDetail.svelte
git commit -m "refactor: update frontend for new SessionState and SubagentInfo.description"
```

---

### Task 8: Final build verification and integration test

- [ ] **Step 1: Run full backend test suite**

Run: `zig build test 2>&1`
Expected: All tests pass, zero failures.

- [ ] **Step 2: Run full build**

Run: `zig build 2>&1`
Expected: Clean build, no warnings.

- [ ] **Step 3: Verify frontend builds**

Run: `cd web && npm run build 2>&1`
Expected: Clean build.

- [ ] **Step 4: Commit any final fixes if needed**

If any test or build issues were found, fix and commit:
```bash
git add -A
git commit -m "fix: resolve build issues from session refactor"
```
