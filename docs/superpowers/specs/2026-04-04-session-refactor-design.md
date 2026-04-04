# Session Layer Refactoring Design

**Date:** 2026-04-04
**Scope:** session.zig, session_manager.zig, hooks.zig, protocol.zig

## Goals

1. Session becomes a self-contained state machine that owns its state transitions
2. Remove hook event history storage — Session only maintains current state
3. Align HookEventType with the full Claude Code hooks API (26 event types)
4. Simplify SessionState to focus on "does the human need to act?"
5. Clean separation: Session (state machine) / SessionManager (thread safety + IO + broadcast)

## Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| Refactoring scope | Full: session + manager + hooks + protocol | Unified redesign avoids half-measures |
| Hook event storage | Minimal — no history, current state only | Events are transient inputs driving state transitions |
| State machine location | Session owns applyEvent() | Session should own its own state; enables pure unit testing |
| HookEventType coverage | All 26 from docs | One-step alignment, even if most are no-ops for now |
| SessionState changes | Remove `starting`, fix `idle`, add `waiting_permission` | Focus on human-action-required states |
| Subagent model | Flat (session-level state), with description field | Simple; subagent asking still sets session.state = .asking |
| PermissionRequest scope | Design for all tools, implement only AskUserQuestion | Future-proof without over-building |
| applyEvent return type | Packed struct of change flags | Simple; SessionManager reads session fields under lock |

## 1. HookEventType — Expand to 26 (hooks.zig)

Replace current 12-variant enum with full coverage:

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
};
```

Update `fromString`/`toString` accordingly. Existing functions (`sendHookToServer`, `readHookInput`, `writeHookOutput`, `ClaudeCodeConfig`) remain unchanged for now — they deal with hook I/O, not session state.

## 2. SessionState — 5 + 1 Reserved

```zig
pub const SessionState = enum {
    running,            // Claude working (absorbs old `starting`)
    asking,             // AskUserQuestion awaiting answer
    waiting_permission, // (reserved) general tool permission request
    waiting_input,      // Terminal prompt awaiting text input
    idle,               // Turn complete, waiting for next user prompt
    stopped,            // PTY process exited
};
```

Key behavioral changes:
- **Remove `starting`**: From phone user's perspective, indistinguishable from `running`. Session.init sets state to `.running`.
- **`idle` only on Stop**: PostToolUse/PostToolUseFailure no longer sets `idle`. This eliminates running/idle flicker during consecutive tool calls.
- **`waiting_permission` reserved**: Enum value exists, protocol encodes it, but no event sets it yet. Future work will hook all PermissionRequest events.

## 3. Session — Self-Contained State Machine (session.zig)

### Removed

- `hook_events: ArrayList(HookEvent)` — no event history storage
- `HookEvent` struct — deleted entirely
- `addHookEvent()` method — deleted
- `setWaitingInput()` / `clearPromptContext()` — replaced by applyEvent internals

### Data Model

```zig
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
};
```

### SubagentInfo — Add description

```zig
pub const SubagentInfo = struct {
    id: []const u8,
    agent_type: []const u8,
    description: []const u8 = "",   // From Agent tool_input.description
    completed: bool = false,
    started_at: i64 = 0,
    elapsed_ms: i64 = 0,
};
```

The `description` field is populated from the SubagentStart event's `agent_type` combined with any context available. Since SubagentStart only provides `agent_id` and `agent_type`, we use `agent_type` as the initial description (e.g., "Explore", "Plan", "code-reviewer"). If richer descriptions are needed in the future, we can correlate with the preceding PreToolUse(Agent) event's `tool_input.description` field, but that adds complexity we don't need now.

### Core Method — applyEvent

```zig
pub const Changes = packed struct {
    state: bool = false,
    prompt: bool = false,
    activity: bool = false,
    last_message: bool = false,
    task: bool = false,
    subagent: bool = false,
};

/// Process a hook event and update internal state.
/// Returns flags indicating what changed, so the caller can
/// broadcast only the relevant protocol messages.
pub fn applyEvent(self: *Session, event_type: HookEventType, raw_json: []const u8) Changes {
    return switch (event_type) {
        .SessionStart => self.handleSessionStart(raw_json),
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
        // All other events: no state change
        else => .{},
    };
}
```

### State Transition Table

| Event | State Transition | Other Changes |
|---|---|---|
| SessionStart | → running | Clear prompt, set last_message="Session started" |
| UserPromptSubmit | → running | Clear prompt |
| PreToolUse | → running | Set current_activity from tool_name |
| PostToolUse/Failure | (no state change) | Clear current_activity |
| PermissionRequest(AskUserQuestion) | → asking | Parse questions, set prompt_context |
| Stop (waiting detected) | → waiting_input | Parse terminal for prompt/options |
| Stop (normal) | → idle | Clear prompt |
| Notification | (no state change) | Set last_message from notification |
| TaskCreated | (no state change) | Append to tasks list |
| TaskCompleted | (no state change) | Mark task completed |
| SubagentStart | (no state change) | Append to subagents list |
| SubagentStop | (no state change) | Mark subagent completed, record elapsed |
| SessionEnd | → stopped | — |
| PTY close (ioRelay) | → stopped | (Set directly by SessionManager) |

### Memory Management

Session owns all allocation/deallocation of its fields:

```zig
// Private helpers (moved from SessionManager)
fn freePromptContext(self: *Session) void;
fn clearCurrentActivity(self: *Session) void;
fn setLastMessage(self: *Session, msg: []const u8) void;
```

`deinit()` updated to remove hook_events cleanup, keep everything else.

## 4. SessionManager — Slim Down (session_manager.zig)

### handleHookEvent — Before vs After

**Before:** ~250 lines of inline event parsing, state transitions, memory management, message encoding.

**After:**
```zig
pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
    const event_type = HookEventType.fromString(event_name) orelse return;

    self.mutex.lock();
    const ms = self.sessions.get(session_id) orelse {
        self.mutex.unlock();
        return;
    };

    const changes = ms.session.applyEvent(event_type, raw_json);

    // Encode protocol messages based on change flags
    var messages: [6]?[]const u8 = .{null} ** 6;
    if (changes.state)
        messages[0] = protocol.encodeSessionStateChange(...);
    if (changes.prompt)
        messages[1] = protocol.encodePromptRequest(...) or encodeAskPromptRequest(...);
    if (changes.activity)
        messages[2] = protocol.encodeActivityUpdate(...);
    if (changes.last_message)
        messages[3] = protocol.encodeLastMessageUpdate(...);
    if (changes.task)
        messages[4] = protocol.encodeTaskUpdate(...);
    if (changes.subagent)
        messages[5] = protocol.encodeSubagentUpdate(...);
    self.mutex.unlock();

    // Broadcast outside lock
    for (messages) |msg| if (msg) |m| {
        defer self.allocator.free(m);
        self.broadcaster.broadcast(m);
    };
}
```

### Removed from SessionManager

- `freePromptContextLocked` → moved to Session.freePromptContext
- `clearCurrentActivityLocked` → moved to Session.clearCurrentActivity
- `setLastMessageLocked` → moved to Session.setLastMessage
- `appendHookEventLocked` → deleted entirely
- `getSessionEvents` / `freeSessionEvents` / `HookEventInfo` — deleted (no event history)

### SessionInfo / dupSessionInfo

Remove `hook_events`-related fields. Add subagent `description` field to snapshot.

## 5. Protocol — Minor Adjustments (protocol.zig)

### Deleted
- `encodeHookEvent()` — no longer broadcasting raw hook events

### Updated
- All `SessionState` switch statements: remove `starting` case, add `waiting_permission` case
- `encodeSubagentUpdate()`: add `description` field

### Unchanged
- All other encode functions (terminal_output, prompt_request, auth_result, etc.)
- JSON escape utilities
- Client message parsing
- `extractToolInputJson`, `buildUpdatedInput`, `buildPermissionHookOutput`

## 6. Data Flow Summary

```
Hook JSON arrives (HTTP or IPC)
  → SessionManager.handleHookEvent(session_id, event_name, raw_json)
    → Parse event_type via HookEventType.fromString
    → mutex.lock()
    → session.applyEvent(event_type, raw_json) → Changes flags
    → Read session fields, encode protocol messages per Changes
    → mutex.unlock()
    → Broadcast messages to WebSocket clients
```

## 7. Existing Bugs to Fix During Refactor

Two bugs identified in current code (via Codex review) that should be fixed as part of this refactor:

### P1: PendingAsk use-after-free on shutdown

`SessionManager.deinit()` (line 101-110) signals the condition variable and immediately destroys the `PendingAsk`, but the waiter thread in `waitPendingAsk()` may still be reading `pa.response` / `pa.tool_input_json`. Fix: let the waiter thread own destruction — `deinit` only signals, does not destroy.

### P2: AskUserQuestion response sets wrong state

`resolvePromptResponse()` (line 636-639) sets `next_state = .idle` after answering an AskUserQuestion. But the hook is still blocked in `waitPendingAsk()` — Claude hasn't received the answer yet, so the session is still working. Fix: after answering asking, transition to `.running` (not `.idle`). The subsequent PostToolUse or Stop event will set the correct final state.

## 8. Testing Strategy

Session.applyEvent is pure state machine logic — test without PTY, broadcaster, or threads:

```zig
test "Stop sets idle" {
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .running;
    const changes = s.applyEvent(.Stop, "{}");
    try testing.expect(changes.state);
    try testing.expectEqual(.idle, s.state);
}

test "PreToolUse sets activity" {
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    const changes = s.applyEvent(.PreToolUse, "{\"tool_name\":\"Bash\"}");
    try testing.expect(changes.activity);
    try testing.expectEqualStrings("Bash", s.current_activity.?.tool_name);
}

test "PostToolUse does NOT set idle" {
    var s = try Session.init(allocator, 1);
    defer s.deinit();
    s.state = .running;
    const changes = s.applyEvent(.PostToolUse, "{}");
    try testing.expectEqual(.running, s.state);
    try testing.expect(!changes.state);
}
```
