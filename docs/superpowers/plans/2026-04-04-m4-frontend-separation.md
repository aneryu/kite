# M4 前后端分离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Kite 从嵌入式 Web 应用改造为前后端分离架构 — 后端纯 API 服务，前端独立 Svelte 项目。

**Architecture:** 后端新增 `--no-auth` 跳过认证、CORS 支持、HTTP hook 端点、静态文件服务改造（删除 web.zig 嵌入式 HTML，改为 `--static-dir` 读取外部文件）。前端使用 Svelte 5 + TypeScript + Vite，通过 WebSocket 和 REST API 与后端通信。保留现有 IPC hook 机制兼容其他工具。

**Tech Stack:** Zig 0.15.2（后端）、Svelte 5 + TypeScript + Vite 6（前端）、xterm.js 5.5（终端渲染）

---

### Task 1: Auth 跳过机制

**Files:**
- Modify: `src/auth.zig:4-7` — Auth struct 增加 disabled 字段
- Modify: `src/main.zig:73-88` — runStart 解析 `--no-auth` 参数
- Modify: `src/http.zig:107-157` — WebSocket 连接跳过 auth 握手
- Modify: `src/ws.zig:50-58` — broadcast 在 auth disabled 时不检查 authenticated

- [ ] **Step 1: 修改 Auth struct，增加 disabled 字段**

在 `src/auth.zig` 的 `Auth` struct 中增加 `disabled` 字段，并修改 `validateSessionToken` 在 disabled 时返回 true：

```zig
pub const Auth = struct {
    secret: [32]u8,
    setup_token: [32]u8,
    session_token: ?[64]u8 = null,
    setup_token_used: bool = false,
    setup_token_created: i64,
    session_token_created: i64 = 0,
    disabled: bool = false,

    // ... 其他字段不变 ...

    pub fn validateSessionToken(self: *const Auth, token_hex: []const u8) bool {
        if (self.disabled) return true;
        if (self.session_token) |session| {
            if (std.time.timestamp() - self.session_token_created > session_token_ttl) return false;
            const expected = std.fmt.bytesToHex(session, .lower);
            return std.mem.eql(u8, token_hex, &expected);
        }
        return false;
    }
```

- [ ] **Step 2: 修改 WebSocket 处理，auth disabled 时自动认证**

在 `src/http.zig` 的 `handleWebSocket` 中，连接建立后立刻检查 auth disabled：

```zig
fn handleWebSocket(self: *Server, head: *http.Server.Request) !void {
    // ... ws upgrade 代码不变 ...

    var client = ws_mod.WsClient{ .ws = ws };
    if (self.auth.disabled) {
        client.authenticated = true;
    }
    try self.broadcaster.addClient(&client);
    defer self.broadcaster.removeClient(&client);

    // ... 后续代码不变 ...
```

- [ ] **Step 3: 在 Config 中增加 no_auth 标志并解析**

在 `src/main.zig` 的 `Config` struct 增加 `no_auth` 字段，`runStart` 中解析 `--no-auth` 参数：

```zig
const Config = struct {
    port: u16 = 7890,
    bind: []const u8 = "0.0.0.0",
    command: []const u8 = "claude",
    attach_id: ?u64 = null,
    static_dir: ?[]const u8 = null,
    no_auth: bool = false,
};
```

在 `runStart` 的参数解析循环中增加：

```zig
} else if (std.mem.eql(u8, args[i], "--no-auth")) {
    config.no_auth = true;
}
```

设置 `auth.disabled = config.no_auth;`（在 `var auth = Auth.init();` 之后）。

- [ ] **Step 4: 更新 help 文本**

在 `printUsage` 中 `--static-dir` 之后添加：

```zig
\\  --no-auth              Disable authentication (dev mode)
```

- [ ] **Step 5: 运行测试并验证**

Run: `zig build test 2>&1`
Expected: PASS（现有 auth token flow 测试不受影响，因为 disabled 默认 false）

- [ ] **Step 6: Commit**

```bash
git add src/auth.zig src/main.zig src/http.zig
git commit -m "feat: add --no-auth flag to disable authentication"
```

---

### Task 2: CORS 支持

**Files:**
- Modify: `src/http.zig:18-25` — Server struct 增加 cors_enabled 字段
- Modify: `src/http.zig:61-105` — handleConnection 处理 OPTIONS 和添加 CORS headers
- Modify: `src/main.zig` — no_auth 时自动启用 CORS

- [ ] **Step 1: Server struct 增加 cors_enabled 字段**

在 `src/http.zig` 的 `Server` struct 中增加：

```zig
cors_enabled: bool = false,
```

- [ ] **Step 2: 添加 CORS headers 辅助方法**

在 `Server` struct 中添加辅助方法：

```zig
const cors_headers = [_]http.Header{
    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
};

fn respondWithCors(self: *Server, head: *http.Server.Request, body: []const u8, options: anytype) !void {
    if (self.cors_enabled) {
        // Build combined headers
        var all_headers: [8]http.Header = undefined;
        var count: usize = 0;
        for (cors_headers) |h| {
            all_headers[count] = h;
            count += 1;
        }
        if (@hasField(@TypeOf(options), "extra_headers")) {
            if (options.extra_headers) |eh| {
                for (eh) |h| {
                    all_headers[count] = h;
                    count += 1;
                }
            }
        }
        try head.respond(body, .{
            .status = if (@hasField(@TypeOf(options), "status")) options.status else .ok,
            .extra_headers = all_headers[0..count],
        });
    } else {
        try head.respond(body, options);
    }
}
```

- [ ] **Step 3: 在 handleConnection 中处理 OPTIONS preflight**

在 `handleConnection` 的路由分发最前面（`/ws` 检查之前）添加：

```zig
// CORS preflight
if (self.cors_enabled and head.head.method == .OPTIONS) {
    try head.respond("", .{
        .status = .no_content,
        .extra_headers = &cors_headers,
    });
    return;
}
```

- [ ] **Step 4: 在 main.zig 中 no_auth 时启用 CORS**

在 `runStart` 中设置 `http_server.cors_enabled = config.no_auth;`。

- [ ] **Step 5: 运行测试**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/http.zig src/main.zig
git commit -m "feat: add CORS support, auto-enabled with --no-auth"
```

---

### Task 3: 删除 web.zig，改造静态文件服务

**Files:**
- Delete: `src/web.zig`
- Modify: `src/http.zig:1-4` — 移除 web import
- Modify: `src/http.zig:412-460` — 重写 serveStaticFile
- Modify: `build.zig` — 确认无 web.zig 依赖

- [ ] **Step 1: 重写 serveStaticFile，移除嵌入式 HTML 依赖**

在 `src/http.zig` 中，移除 `const web = @import("web.zig");`，并重写 `serveStaticFile`：

```zig
fn serveStaticFile(self: *Server, head: *http.Server.Request, path: []const u8) !void {
    const dir = self.static_dir orelse {
        try head.respond("{\"error\":\"not found\"}", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
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
```

- [ ] **Step 2: 删除 web.zig**

```bash
rm src/web.zig
```

- [ ] **Step 3: 运行构建和测试**

Run: `zig build 2>&1 && zig build test 2>&1`
Expected: BUILD SUCCESS, TESTS PASS

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: remove embedded HTML, static files served from --static-dir only"
```

---

### Task 4: HTTP Hook 端点

**Files:**
- Modify: `src/http.zig` — 新增 `/api/v1/hooks` POST 路由和 handleHttpHook 方法
- Modify: `src/hooks.zig:4-33` — HookEventType 增加新事件类型
- Modify: `src/session.zig:67-74` — 增加 Task、Subagent、Activity 数据结构
- Modify: `src/session_manager.zig:190-218` — handleHookEvent 处理新事件类型

- [ ] **Step 1: 扩展 HookEventType，增加新事件类型**

在 `src/hooks.zig` 的 `HookEventType` enum 和映射中增加：

```zig
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
        };
    }
};
```

- [ ] **Step 2: 扩展 Session 数据模型**

在 `src/session.zig` 中添加新的数据结构：

```zig
pub const TaskInfo = struct {
    id: []const u8,
    subject: []const u8,
    description: []const u8 = "",
    completed: bool = false,
};

pub const SubagentInfo = struct {
    id: []const u8,
    agent_type: []const u8,
    completed: bool = false,
    started_at: i64 = 0,
    elapsed_ms: i64 = 0,
};

pub const ActivityInfo = struct {
    tool_name: []const u8,
    summary: []const u8 = "",
};
```

在 `Session` struct 中增加字段：

```zig
tasks: std.ArrayList(TaskInfo),
subagents: std.ArrayList(SubagentInfo),
current_activity: ?ActivityInfo = null,
```

修改 `Session.init` 初始化新字段：

```zig
.tasks = .empty,
.subagents = .empty,
```

修改 `Session.deinit` 释放新字段：

```zig
// 释放 tasks 中的字符串
for (self.tasks.items) |task| {
    self.allocator.free(task.id);
    self.allocator.free(task.subject);
    if (task.description.len > 0) self.allocator.free(task.description);
}
self.tasks.deinit(self.allocator);

// 释放 subagents 中的字符串
for (self.subagents.items) |sa| {
    self.allocator.free(sa.id);
    self.allocator.free(sa.agent_type);
}
self.subagents.deinit(self.allocator);

// 释放 current_activity
if (self.current_activity) |act| {
    self.allocator.free(act.tool_name);
    if (act.summary.len > 0) self.allocator.free(act.summary);
}
```

- [ ] **Step 3: 扩展 handleHookEvent 处理新事件**

在 `src/session_manager.zig` 的 `handleHookEvent` 中增加对新事件的处理：

```zig
pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
    const session = self.getSession(session_id) orelse return;

    if (std.mem.eql(u8, event_name, "Stop")) {
        // ... 现有 Stop 处理不变 ...
    } else if (std.mem.eql(u8, event_name, "SessionStart")) {
        session.state = .running;
        session.clearPromptContext();
    } else if (std.mem.eql(u8, event_name, "PreToolUse")) {
        self.handlePreToolUse(session, raw_json);
    } else if (std.mem.eql(u8, event_name, "PostToolUse") or std.mem.eql(u8, event_name, "PostToolUseFailure")) {
        // Clear current activity
        if (session.current_activity) |act| {
            self.allocator.free(act.tool_name);
            if (act.summary.len > 0) self.allocator.free(act.summary);
            session.current_activity = null;
        }
    } else if (std.mem.eql(u8, event_name, "TaskCreated")) {
        self.handleTaskCreated(session, raw_json);
    } else if (std.mem.eql(u8, event_name, "TaskCompleted")) {
        self.handleTaskCompleted(session, raw_json);
    } else if (std.mem.eql(u8, event_name, "SubagentStart")) {
        self.handleSubagentStart(session, raw_json);
    } else if (std.mem.eql(u8, event_name, "SubagentStop")) {
        self.handleSubagentStop(session, raw_json);
    }

    // Broadcast state change
    const state_msg = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch return;
    defer self.allocator.free(state_msg);
    self.broadcaster.broadcast(state_msg);
}

fn handlePreToolUse(self: *SessionManager, session: *Session, raw_json: []const u8) void {
    const Payload = struct { tool_name: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    // Clear previous activity
    if (session.current_activity) |act| {
        self.allocator.free(act.tool_name);
        if (act.summary.len > 0) self.allocator.free(act.summary);
    }
    session.current_activity = .{
        .tool_name = self.allocator.dupe(u8, parsed.value.tool_name) catch return,
    };
}

fn handleTaskCreated(self: *SessionManager, session: *Session, raw_json: []const u8) void {
    const Payload = struct {
        task_id: []const u8 = "",
        task_subject: []const u8 = "",
        task_description: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const task = Session.TaskInfo{
        .id = self.allocator.dupe(u8, parsed.value.task_id) catch return,
        .subject = self.allocator.dupe(u8, parsed.value.task_subject) catch return,
        .description = if (parsed.value.task_description.len > 0)
            self.allocator.dupe(u8, parsed.value.task_description) catch return
        else
            "",
    };
    session.tasks.append(self.allocator, task) catch return;
}

fn handleTaskCompleted(self: *SessionManager, session: *Session, raw_json: []const u8) void {
    const Payload = struct { task_id: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    for (session.tasks.items) |*task| {
        if (std.mem.eql(u8, task.id, parsed.value.task_id)) {
            task.completed = true;
            break;
        }
    }
}

fn handleSubagentStart(self: *SessionManager, session: *Session, raw_json: []const u8) void {
    const Payload = struct {
        agent_id: []const u8 = "",
        agent_type: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const sa = Session.SubagentInfo{
        .id = self.allocator.dupe(u8, parsed.value.agent_id) catch return,
        .agent_type = self.allocator.dupe(u8, parsed.value.agent_type) catch return,
        .started_at = std.time.timestamp(),
    };
    session.subagents.append(self.allocator, sa) catch return;
}

fn handleSubagentStop(self: *SessionManager, session: *Session, raw_json: []const u8) void {
    const Payload = struct { agent_id: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Payload, self.allocator, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    for (session.subagents.items) |*sa| {
        if (std.mem.eql(u8, sa.id, parsed.value.agent_id)) {
            sa.completed = true;
            sa.elapsed_ms = (std.time.timestamp() - sa.started_at) * 1000;
            break;
        }
    }
}
```

- [ ] **Step 4: 在 http.zig 中添加 HTTP hook 路由和处理**

在 `handleConnection` 的路由分发中，在 auth 路由之后添加：

```zig
if (std.mem.eql(u8, path, "/api/v1/hooks") and head.head.method == .POST) {
    self.handleHttpHook(&head) catch {};
    return;
}
```

添加 `handleHttpHook` 方法：

```zig
fn handleHttpHook(self: *Server, head: *http.Server.Request) !void {
    var body_buf: [8192]u8 = undefined;
    const io_reader = head.readerExpectNone(&body_buf);
    var body: [8192]u8 = undefined;
    var bufs: [1][]u8 = .{&body};
    const body_len = io_reader.readVec(&bufs) catch 0;
    const body_slice = body[0..body_len];

    // Parse the hook event
    const HookPayload = struct {
        hook_event_name: []const u8 = "",
        session_id: []const u8 = "",
        tool_name: ?[]const u8 = null,
        task_id: ?[]const u8 = null,
        task_subject: ?[]const u8 = null,
        task_description: ?[]const u8 = null,
        agent_id: ?[]const u8 = null,
        agent_type: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(HookPayload, self.allocator, body_slice, .{
        .ignore_unknown_fields = true,
    }) catch {
        try head.respond("{\"error\":\"invalid json\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return;
    };
    defer parsed.deinit();

    const event_name = parsed.value.hook_event_name;
    if (event_name.len == 0) {
        try head.respond("{\"error\":\"missing hook_event_name\"}", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return;
    }

    // Determine session_id (default to 1)
    var session_id: u64 = 1;
    if (parsed.value.session_id.len > 0) {
        session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
    }

    // Broadcast as hook event to WebSocket clients
    const tool_name = parsed.value.tool_name orelse "";
    const msg = protocol.encodeHookEvent(self.allocator, event_name, tool_name, body_slice, session_id) catch {
        try head.respond("{\"ok\":true}", .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        return;
    };
    defer self.allocator.free(msg);
    self.broadcaster.broadcast(msg);

    // Update session state
    self.session_manager.handleHookEvent(session_id, event_name, body_slice);

    try head.respond("{\"ok\":true}", .{
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
    });
}
```

- [ ] **Step 5: 运行测试**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/hooks.zig src/session.zig src/session_manager.zig src/http.zig
git commit -m "feat: add HTTP hook endpoint and extended session data model"
```

---

### Task 5: 扩展 Sessions API 返回 tasks/subagents/activity

**Files:**
- Modify: `src/http.zig` — handleSessionsApi 的 GET 响应增加新字段
- Modify: `src/session_manager.zig` — SessionInfo 增加新字段，listSessions 填充
- Modify: `src/protocol.zig` — 新增 encodeSessionDetail 编码完整 session 信息

- [ ] **Step 1: 扩展 SessionInfo**

在 `src/session_manager.zig` 中扩展 `SessionInfo`：

```zig
pub const SessionInfo = struct {
    id: u64,
    state: @import("session.zig").SessionState,
    command: []const u8,
    cwd: []const u8,
    tasks: []const @import("session.zig").TaskInfo,
    subagents: []const @import("session.zig").SubagentInfo,
    current_activity: ?@import("session.zig").ActivityInfo = null,
};
```

更新 `listSessions` 填充新字段：

```zig
try list.append(allocator, .{
    .id = ms.session.id,
    .state = ms.session.state,
    .command = ms.session.command,
    .cwd = ms.session.cwd,
    .tasks = ms.session.tasks.items,
    .subagents = ms.session.subagents.items,
    .current_activity = ms.session.current_activity,
});
```

- [ ] **Step 2: 扩展 handleSessionsApi 的 JSON 输出**

在 `src/http.zig` 的 `handleSessionsApi` 中，GET 列表和 GET 单个 session 的响应中增加 tasks、subagents、current_activity 字段。

列表响应中每个 session 的 JSON 构建：

```zig
// Build tasks array
var tasks_json: std.ArrayList(u8) = .empty;
defer tasks_json.deinit(self.allocator);
try tasks_json.appendSlice(self.allocator, "[");
for (s.tasks, 0..) |task, ti| {
    if (ti > 0) try tasks_json.appendSlice(self.allocator, ",");
    const task_entry = std.fmt.allocPrint(self.allocator,
        \\{{"id":"{s}","subject":"{s}","completed":{s}}}
    , .{ task.id, task.subject, if (task.completed) "true" else "false" }) catch continue;
    defer self.allocator.free(task_entry);
    try tasks_json.appendSlice(self.allocator, task_entry);
}
try tasks_json.appendSlice(self.allocator, "]");

// Build subagents array
var sa_json: std.ArrayList(u8) = .empty;
defer sa_json.deinit(self.allocator);
try sa_json.appendSlice(self.allocator, "[");
for (s.subagents, 0..) |sa, si| {
    if (si > 0) try sa_json.appendSlice(self.allocator, ",");
    const sa_entry = std.fmt.allocPrint(self.allocator,
        \\{{"id":"{s}","type":"{s}","completed":{s},"elapsed_ms":{d}}}
    , .{ sa.id, sa.agent_type, if (sa.completed) "true" else "false", sa.elapsed_ms }) catch continue;
    defer self.allocator.free(sa_entry);
    try sa_json.appendSlice(self.allocator, sa_entry);
}
try sa_json.appendSlice(self.allocator, "]");

// Activity
const activity_str = if (s.current_activity) |act|
    std.fmt.allocPrint(self.allocator,
        \\{{"tool_name":"{s}"}}
    , .{act.tool_name}) catch "null"
else
    "null";
const activity_needs_free = s.current_activity != null;
defer if (activity_needs_free) self.allocator.free(activity_str);

const entry = std.fmt.allocPrint(self.allocator,
    \\{{"id":{d},"state":"{s}","command":"{s}","cwd":"{s}","tasks":{s},"subagents":{s},"activity":{s}}}
, .{ s.id, state_str, s.command, s.cwd, tasks_json.items, sa_json.items, activity_str }) catch continue;
defer self.allocator.free(entry);
try json_buf.appendSlice(self.allocator, entry);
```

- [ ] **Step 3: 运行测试**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/http.zig src/session_manager.zig
git commit -m "feat: sessions API returns tasks, subagents, and current activity"
```

---

### Task 6: 更新 kite setup 生成 HTTP hooks 配置

**Files:**
- Modify: `src/hooks.zig:91-127` — 更新 generateHooksConfig 生成 HTTP hooks

- [ ] **Step 1: 更新 generateHooksConfig**

在 `src/hooks.zig` 中重写 `generateHooksConfig`，生成 HTTP 类型的 hooks 配置（保留现有的 command 类型方法作为参考，新增 HTTP 版本）：

```zig
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
            \\    "SessionStart": [{{"matcher": "*", "hooks": [{{"type": "http", "url": "http://localhost:{d}/api/v1/hooks"}}]}}]
            \\  }}
            \\}}
        , .{ port, port, port, port, port, port, port, port, port, port, port });
    }
};
```

- [ ] **Step 2: 更新 runSetup 调用**

在 `src/main.zig` 的 `runSetup` 中更新调用：

```zig
fn runSetup(allocator: std.mem.Allocator) !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    const config = try hooks.ClaudeCodeConfig.generateHooksConfig(allocator, 7890);
    defer allocator.free(config);

    try stdout.print("Add the following to your Claude Code settings\n", .{});
    try stdout.print("(~/.claude/settings.json or .claude/settings.json):\n\n", .{});
    try stdout.print("{s}\n", .{config});
    try stdout.flush();
}
```

- [ ] **Step 3: 运行测试**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/hooks.zig src/main.zig
git commit -m "feat: kite setup generates HTTP hooks config for Claude Code"
```

---

### Task 7: WebSocket 广播 tasks/subagents/activity 变更

**Files:**
- Modify: `src/protocol.zig` — 新增编码函数
- Modify: `src/session_manager.zig` — hook 处理后广播详细变更消息

- [ ] **Step 1: 在 protocol.zig 中新增编码函数**

```zig
pub fn encodeTaskUpdate(allocator: std.mem.Allocator, session_id: u64, task_id: []const u8, subject: []const u8, completed: bool) ![]u8 {
    const escaped_subject = try jsonEscapeAlloc(allocator, subject);
    defer allocator.free(escaped_subject);
    return std.fmt.allocPrint(allocator,
        \\{{"type":"task_update","session_id":{d},"task_id":"{s}","subject":"{s}","completed":{s}}}
    , .{ session_id, task_id, escaped_subject, if (completed) "true" else "false" });
}

pub fn encodeSubagentUpdate(allocator: std.mem.Allocator, session_id: u64, agent_id: []const u8, agent_type: []const u8, completed: bool, elapsed_ms: i64) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"type":"subagent_update","session_id":{d},"agent_id":"{s}","agent_type":"{s}","completed":{s},"elapsed_ms":{d}}}
    , .{ session_id, agent_id, agent_type, if (completed) "true" else "false", elapsed_ms });
}

pub fn encodeActivityUpdate(allocator: std.mem.Allocator, session_id: u64, tool_name: ?[]const u8) ![]u8 {
    if (tool_name) |tn| {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"activity_update","session_id":{d},"tool_name":"{s}"}}
        , .{ session_id, tn });
    } else {
        return std.fmt.allocPrint(allocator,
            \\{{"type":"activity_update","session_id":{d},"tool_name":null}}
        , .{session_id});
    }
}
```

- [ ] **Step 2: 在 handleHookEvent 各处理分支中广播变更**

在 `session_manager.zig` 的各 handle 方法末尾，广播对应消息。例如在 `handleTaskCreated` 末尾：

```zig
const ws_msg = protocol.encodeTaskUpdate(self.allocator, session.id, task.id, task.subject, false) catch return;
defer self.allocator.free(ws_msg);
self.broadcaster.broadcast(ws_msg);
```

类似地在 `handleTaskCompleted`、`handleSubagentStart`、`handleSubagentStop`、`handlePreToolUse` 和 PostToolUse 清除 activity 处添加广播。

- [ ] **Step 3: 运行测试**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/protocol.zig src/session_manager.zig
git commit -m "feat: broadcast task/subagent/activity updates via WebSocket"
```

---

### Task 8: 搭建 Svelte 前端项目

**Files:**
- Create: `web/package.json`
- Create: `web/tsconfig.json`
- Create: `web/vite.config.ts`
- Create: `web/index.html`
- Create: `web/src/main.ts`
- Create: `web/src/App.svelte`
- Create: `web/src/app.css`
- Modify: `.gitignore` — 添加 web/node_modules、web/dist

- [ ] **Step 1: 初始化项目**

```bash
mkdir -p web/src
```

- [ ] **Step 2: 创建 package.json**

```json
{
  "name": "kite-web",
  "private": true,
  "version": "0.0.1",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "^5.0.0",
    "svelte": "^5.0.0",
    "typescript": "^5.7.0",
    "vite": "^6.0.0"
  },
  "dependencies": {
    "@xterm/xterm": "^5.5.0",
    "@xterm/addon-fit": "^0.10.0"
  }
}
```

- [ ] **Step 3: 创建 vite.config.ts**

```typescript
import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:7890',
      '/ws': {
        target: 'ws://localhost:7890',
        ws: true,
      },
    },
  },
});
```

- [ ] **Step 4: 创建 tsconfig.json**

```json
{
  "extends": "@sveltejs/vite-plugin-svelte/tsconfig/tsconfig.json",
  "compilerOptions": {
    "target": "ESNext",
    "useDefineForClassFields": true,
    "module": "ESNext",
    "resolveJsonModule": true,
    "allowJs": true,
    "checkJs": true,
    "isolatedModules": true,
    "moduleDetection": "force"
  },
  "include": ["src/**/*.ts", "src/**/*.svelte"]
}
```

- [ ] **Step 5: 创建 index.html**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Kite</title>
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.ts"></script>
</body>
</html>
```

- [ ] **Step 6: 创建 src/app.css（沿用暗色主题）**

```css
:root {
  --bg: #0a0a0a;
  --fg: #e0e0e0;
  --accent: #4fc3f7;
  --card-bg: #1a1a1a;
  --border: #333;
  --danger: #ef5350;
  --success: #66bb6a;
  --warn: #ffa726;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  background: var(--bg);
  color: var(--fg);
  height: 100dvh;
  overflow: hidden;
}

#app {
  display: flex;
  flex-direction: column;
  height: 100dvh;
}
```

- [ ] **Step 7: 创建 src/main.ts**

```typescript
import App from './App.svelte';
import { mount } from 'svelte';
import './app.css';

const app = mount(App, { target: document.getElementById('app')! });

export default app;
```

- [ ] **Step 8: 创建 src/App.svelte（空壳）**

```svelte
<script lang="ts">
  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);

  function openSession(id: number) {
    selectedSessionId = id;
    currentView = 'detail';
  }

  function goBack() {
    currentView = 'list';
    selectedSessionId = null;
  }
</script>

<main>
  {#if currentView === 'list'}
    <header>
      <h1>Kite</h1>
    </header>
    <p style="padding: 1rem; color: var(--fg);">Session list coming soon...</p>
  {:else}
    <header>
      <button onclick={goBack}>&larr;</button>
      <h1>Session {selectedSessionId}</h1>
    </header>
    <p style="padding: 1rem; color: var(--fg);">Terminal coming soon...</p>
  {/if}
</main>

<style>
  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 1rem;
    background: var(--card-bg);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }

  header h1 {
    font-size: 1rem;
    color: var(--accent);
  }

  header button {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 1.2rem;
    cursor: pointer;
    padding: 0 0.5rem;
  }

  main {
    display: flex;
    flex-direction: column;
    height: 100dvh;
  }
</style>
```

- [ ] **Step 9: 更新 .gitignore**

添加：
```
web/node_modules/
web/dist/
```

- [ ] **Step 10: 安装依赖并验证**

Run: `cd web && npm install && npm run build`
Expected: 构建成功，产物在 web/dist/

- [ ] **Step 11: Commit**

```bash
git add web/ .gitignore
git commit -m "feat: scaffold Svelte 5 + Vite frontend project"
```

---

### Task 9: WebSocket 连接管理器和 API 客户端

**Files:**
- Create: `web/src/lib/ws.ts`
- Create: `web/src/lib/api.ts`
- Create: `web/src/lib/types.ts`

- [ ] **Step 1: 创建 types.ts（共享类型定义）**

```typescript
export interface TaskInfo {
  id: string;
  subject: string;
  completed: boolean;
}

export interface SubagentInfo {
  id: string;
  type: string;
  completed: boolean;
  elapsed_ms: number;
}

export interface ActivityInfo {
  tool_name: string;
}

export interface SessionInfo {
  id: number;
  state: 'starting' | 'running' | 'waiting_input' | 'stopped';
  command: string;
  cwd: string;
  tasks: TaskInfo[];
  subagents: SubagentInfo[];
  activity: ActivityInfo | null;
}

export interface ServerMessage {
  type: string;
  session_id?: number;
  data?: string;
  state?: string;
  event?: string;
  tool?: string;
  tool_name?: string | null;
  task_id?: string;
  subject?: string;
  completed?: boolean;
  agent_id?: string;
  agent_type?: string;
  elapsed_ms?: number;
  summary?: string;
  options?: string[];
  success?: boolean;
}
```

- [ ] **Step 2: 创建 api.ts**

```typescript
const BASE = '';  // Uses Vite proxy in dev, same origin in prod

export async function fetchSessions(): Promise<import('./types').SessionInfo[]> {
  const res = await fetch(`${BASE}/api/v1/sessions`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function createSession(command = 'claude'): Promise<{ session_id: number }> {
  const res = await fetch(`${BASE}/api/v1/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ command }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function deleteSession(id: number): Promise<void> {
  await fetch(`${BASE}/api/v1/sessions/${id}`, { method: 'DELETE' });
}

export async function fetchTerminalSnapshot(id: number): Promise<string> {
  const res = await fetch(`${BASE}/api/v1/sessions/${id}/terminal`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  return data.data ? atob(data.data) : '';
}
```

- [ ] **Step 3: 创建 ws.ts**

```typescript
import type { ServerMessage } from './types';

type MessageHandler = (msg: ServerMessage) => void;

export class WsManager {
  private ws: WebSocket | null = null;
  private handlers: MessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private url: string;

  constructor() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.url = `${proto}//${location.host}/ws`;
  }

  connect() {
    if (this.ws?.readyState === WebSocket.OPEN) return;

    this.ws = new WebSocket(this.url);

    this.ws.onmessage = (ev) => {
      try {
        const msg: ServerMessage = JSON.parse(ev.data);
        this.handlers.forEach((h) => h(msg));
      } catch {}
    };

    this.ws.onclose = () => {
      this.scheduleReconnect();
    };

    this.ws.onerror = () => {
      this.ws?.close();
    };
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 2000);
  }

  onMessage(handler: MessageHandler) {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  sendTerminalInput(data: string, sessionId: number) {
    this.send({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number) {
    this.send({ type: 'resize', cols, rows, session_id: sessionId });
  }

  sendPromptResponse(text: string, sessionId: number) {
    this.send({ type: 'prompt_response', text, session_id: sessionId });
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  disconnect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
  }
}

export const ws = new WsManager();
```

- [ ] **Step 4: 验证构建**

Run: `cd web && npm run build`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/
git commit -m "feat: add WebSocket manager, API client, and shared types"
```

---

### Task 10: Session Store

**Files:**
- Create: `web/src/stores/sessions.ts`

- [ ] **Step 1: 创建 sessions store**

```typescript
import { ws } from '../lib/ws';
import { fetchSessions } from '../lib/api';
import type { SessionInfo, TaskInfo, SubagentInfo, ServerMessage } from '../lib/types';

// Reactive state using Svelte 5 runes (module-level $state requires .svelte.ts)
// We use a simple pub/sub pattern for plain .ts files
type Listener = () => void;

class SessionStore {
  sessions: SessionInfo[] = [];
  private listeners: Listener[] = [];

  subscribe(fn: Listener) {
    this.listeners.push(fn);
    return () => {
      this.listeners = this.listeners.filter((l) => l !== fn);
    };
  }

  private notify() {
    this.listeners.forEach((fn) => fn());
  }

  async load() {
    try {
      this.sessions = await fetchSessions();
      this.notify();
    } catch {}
  }

  getSession(id: number): SessionInfo | undefined {
    return this.sessions.find((s) => s.id === id);
  }

  handleMessage(msg: ServerMessage) {
    const sid = msg.session_id;
    if (!sid) return;

    switch (msg.type) {
      case 'session_state_change': {
        const s = this.getSession(sid);
        if (s && msg.state) {
          s.state = msg.state as SessionInfo['state'];
          this.notify();
        }
        break;
      }
      case 'task_update': {
        const s = this.getSession(sid);
        if (!s || !msg.task_id) break;
        const existing = s.tasks.find((t) => t.id === msg.task_id);
        if (existing) {
          existing.completed = msg.completed ?? existing.completed;
        } else {
          s.tasks.push({
            id: msg.task_id,
            subject: msg.subject ?? '',
            completed: msg.completed ?? false,
          });
        }
        this.notify();
        break;
      }
      case 'subagent_update': {
        const s = this.getSession(sid);
        if (!s || !msg.agent_id) break;
        const existing = s.subagents.find((a) => a.id === msg.agent_id);
        if (existing) {
          existing.completed = msg.completed ?? existing.completed;
          existing.elapsed_ms = msg.elapsed_ms ?? existing.elapsed_ms;
        } else {
          s.subagents.push({
            id: msg.agent_id,
            type: msg.agent_type ?? '',
            completed: msg.completed ?? false,
            elapsed_ms: msg.elapsed_ms ?? 0,
          });
        }
        this.notify();
        break;
      }
      case 'activity_update': {
        const s = this.getSession(sid);
        if (!s) break;
        s.activity = msg.tool_name ? { tool_name: msg.tool_name } : null;
        this.notify();
        break;
      }
      case 'prompt_request': {
        const s = this.getSession(sid);
        if (s) {
          s.state = 'waiting_input';
          this.notify();
        }
        break;
      }
    }
  }

  /** Sort: waiting_input first, then running, then stopped */
  sorted(): SessionInfo[] {
    const priority: Record<string, number> = {
      waiting_input: 0,
      running: 1,
      starting: 2,
      stopped: 3,
    };
    return [...this.sessions].sort(
      (a, b) => (priority[a.state] ?? 9) - (priority[b.state] ?? 9)
    );
  }
}

export const sessionStore = new SessionStore();

// Wire up WebSocket → store
ws.onMessage((msg) => sessionStore.handleMessage(msg));
```

- [ ] **Step 2: 验证构建**

Run: `cd web && npm run build`
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add web/src/stores/
git commit -m "feat: add session store with WebSocket-driven state updates"
```

---

### Task 11: SessionList 和 SessionCard 组件

**Files:**
- Create: `web/src/components/SessionList.svelte`
- Create: `web/src/components/SessionCard.svelte`
- Modify: `web/src/App.svelte` — 集成 SessionList

- [ ] **Step 1: 创建 SessionCard.svelte**

```svelte
<script lang="ts">
  import type { SessionInfo } from '../lib/types';

  let { session, onclick }: { session: SessionInfo; onclick: () => void } = $props();

  const completedTasks = $derived(session.tasks.filter((t) => t.completed).length);
  const pendingTasks = $derived(session.tasks.length - completedTasks);
  const completedAgents = $derived(session.subagents.filter((a) => a.completed).length);
  const runningAgents = $derived(session.subagents.length - completedAgents);

  function formatElapsed(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${Math.round(ms / 1000)}s`;
  }
</script>

<button class="card" class:waiting={session.state === 'waiting_input'} {onclick}>
  <!-- Header -->
  <div class="row">
    <span class="title">{session.cwd.split('/').pop() || session.command}</span>
    <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
  </div>

  <!-- Current activity -->
  {#if session.activity}
    <div class="activity">{session.activity.tool_name}</div>
  {/if}

  <!-- Tasks -->
  {#if session.tasks.length > 0}
    <div class="section">
      <div class="section-header">Tasks ({completedTasks} done, {pendingTasks} pending)</div>
      {#each session.tasks.slice(0, 5) as task}
        <div class="item" class:done={task.completed}>
          <span class="icon">{task.completed ? '✅' : '☐'}</span>
          <span class="text">{task.subject}</span>
        </div>
      {/each}
      {#if session.tasks.length > 5}
        <div class="more">... +{session.tasks.length - 5} more</div>
      {/if}
    </div>
  {/if}

  <!-- Subagents -->
  {#if session.subagents.length > 0}
    <div class="section">
      <div class="section-header">Subagents ({session.subagents.length})</div>
      {#each session.subagents.slice(0, 4) as agent}
        <div class="item" class:done={agent.completed}>
          <span class="icon">{agent.completed ? '🟢' : '🔵'}</span>
          <span class="text">{agent.type}</span>
          <span class="elapsed">
            {agent.completed ? formatElapsed(agent.elapsed_ms) : '...'}
          </span>
        </div>
      {/each}
      {#if session.subagents.length > 4}
        <div class="more">... +{session.subagents.length - 4} more</div>
      {/if}
    </div>
  {/if}
</button>

<style>
  .card {
    display: block;
    width: 100%;
    text-align: left;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 0.85rem 1rem;
    cursor: pointer;
    transition: border-color 0.15s;
    color: var(--fg);
    font-family: inherit;
    font-size: inherit;
  }
  .card:active { border-color: var(--accent); }
  .card.waiting { border-color: var(--warn); }

  .row { display: flex; justify-content: space-between; align-items: center; }
  .title { font-weight: 600; font-size: 0.85rem; }

  .status {
    font-size: 0.7rem;
    padding: 0.15rem 0.5rem;
    border-radius: 4px;
  }
  .status.running { background: var(--success); color: #000; }
  .status.waiting_input { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  .status.stopped { background: var(--danger); color: #fff; }
  .status.starting { background: var(--accent); color: #000; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }

  .activity {
    color: var(--accent);
    font-size: 0.8rem;
    margin-top: 0.3rem;
    font-family: monospace;
  }

  .section {
    margin-top: 0.5rem;
    padding-top: 0.5rem;
    border-top: 1px solid var(--border);
  }
  .section-header {
    font-size: 0.75rem;
    color: #888;
    margin-bottom: 0.3rem;
  }

  .item {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    font-size: 0.8rem;
    padding: 0.1rem 0;
  }
  .item.done { opacity: 0.5; }
  .icon { flex-shrink: 0; font-size: 0.75rem; }
  .text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .elapsed { color: #888; font-size: 0.7rem; flex-shrink: 0; }
  .more { color: #666; font-size: 0.75rem; padding-left: 1.2rem; }
</style>
```

- [ ] **Step 2: 创建 SessionList.svelte**

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import SessionCard from './SessionCard.svelte';
  import { sessionStore } from '../stores/sessions';
  import { createSession } from '../lib/api';

  let { onselect }: { onselect: (id: number) => void } = $props();
  let sessions = $state(sessionStore.sorted());

  onMount(() => {
    sessionStore.load();
    const unsub = sessionStore.subscribe(() => {
      sessions = sessionStore.sorted();
    });
    const interval = setInterval(() => sessionStore.load(), 5000);
    return () => { unsub(); clearInterval(interval); };
  });

  async function handleCreate() {
    try {
      await createSession();
      await sessionStore.load();
    } catch {}
  }
</script>

<div class="list">
  {#each sessions as session (session.id)}
    <SessionCard {session} onclick={() => onselect(session.id)} />
  {/each}

  {#if sessions.length === 0}
    <p class="empty">No sessions. Create one with <code>kite run</code> or tap +</p>
  {/if}
</div>

<button class="fab" onclick={handleCreate}>+</button>

<style>
  .list {
    flex: 1;
    overflow-y: auto;
    padding: 0.75rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    -webkit-overflow-scrolling: touch;
  }
  .empty {
    text-align: center;
    color: #666;
    padding: 2rem;
  }
  .empty code {
    color: var(--accent);
  }
  .fab {
    position: fixed;
    bottom: 1.5rem;
    right: 1.5rem;
    width: 52px;
    height: 52px;
    border-radius: 50%;
    border: none;
    background: var(--accent);
    color: #000;
    font-size: 1.5rem;
    font-weight: 700;
    cursor: pointer;
    box-shadow: 0 2px 8px rgba(0,0,0,0.4);
    z-index: 10;
  }
</style>
```

- [ ] **Step 3: 更新 App.svelte 集成 SessionList**

```svelte
<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import { ws } from './lib/ws';
  import { onMount } from 'svelte';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);

  onMount(() => {
    ws.connect();
    return () => ws.disconnect();
  });

  function openSession(id: number) {
    selectedSessionId = id;
    currentView = 'detail';
  }

  function goBack() {
    currentView = 'list';
    selectedSessionId = null;
  }
</script>

<main>
  {#if currentView === 'list'}
    <header>
      <h1>Kite</h1>
    </header>
    <SessionList onselect={openSession} />
  {:else}
    <header>
      <button class="back" onclick={goBack}>&larr;</button>
      <h1>Session {selectedSessionId}</h1>
    </header>
    <p style="padding: 1rem; color: var(--fg);">Terminal coming next...</p>
  {/if}
</main>

<style>
  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 1rem;
    background: var(--card-bg);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  header h1 { font-size: 1rem; color: var(--accent); }
  .back {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 1.2rem;
    cursor: pointer;
    padding: 0 0.5rem;
  }
  main {
    display: flex;
    flex-direction: column;
    height: 100dvh;
  }
</style>
```

- [ ] **Step 4: 验证构建**

Run: `cd web && npm run build`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add web/src/
git commit -m "feat: add SessionList and SessionCard components with rich status display"
```

---

### Task 12: TerminalView 和 SessionDetail 组件

**Files:**
- Create: `web/src/components/TerminalView.svelte`
- Create: `web/src/components/SessionDetail.svelte`
- Modify: `web/src/App.svelte` — 集成 SessionDetail

- [ ] **Step 1: 创建 TerminalView.svelte**

```svelte
<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import { ws } from '../lib/ws';
  import { fetchTerminalSnapshot } from '../lib/api';
  import type { ServerMessage } from '../lib/types';
  import '@xterm/xterm/css/xterm.css';

  let { sessionId }: { sessionId: number } = $props();
  let containerEl: HTMLDivElement;
  let terminal: Terminal;
  let fitAddon: FitAddon;
  let unsubscribe: (() => void) | null = null;

  onMount(async () => {
    terminal = new Terminal({
      fontSize: 14,
      fontFamily: "'Hack Nerd Font Mono', 'Fira Code', monospace",
      theme: {
        background: '#0a0a0a',
        foreground: '#e0e0e0',
        cursor: '#4fc3f7',
      },
      cursorBlink: true,
      scrollback: 5000,
    });

    fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(containerEl);
    fitAddon.fit();

    // Send resize
    ws.sendResize(terminal.cols, terminal.rows, sessionId);

    // Load terminal history
    try {
      const snapshot = await fetchTerminalSnapshot(sessionId);
      if (snapshot) terminal.write(snapshot);
    } catch {}

    // Handle incoming terminal output
    unsubscribe = ws.onMessage((msg: ServerMessage) => {
      if (msg.type === 'terminal_output' && msg.session_id === sessionId && msg.data) {
        terminal.write(atob(msg.data));
      }
    });

    // Handle terminal input
    terminal.onData((data: string) => {
      ws.sendTerminalInput(data, sessionId);
    });

    // Handle resize
    const resizeObserver = new ResizeObserver(() => {
      fitAddon.fit();
      ws.sendResize(terminal.cols, terminal.rows, sessionId);
    });
    resizeObserver.observe(containerEl);

    return () => {
      resizeObserver.disconnect();
    };
  });

  onDestroy(() => {
    unsubscribe?.();
    terminal?.dispose();
  });
</script>

<div class="terminal-container" bind:this={containerEl}></div>

<style>
  .terminal-container {
    flex: 1;
    overflow: hidden;
  }
</style>
```

- [ ] **Step 2: 创建 SessionDetail.svelte**

```svelte
<script lang="ts">
  import TerminalView from './TerminalView.svelte';
  import PromptOverlay from './PromptOverlay.svelte';
  import { sessionStore } from '../stores/sessions';
  import { ws } from '../lib/ws';

  let { sessionId, onback }: { sessionId: number; onback: () => void } = $props();

  let session = $derived(sessionStore.getSession(sessionId));
  let showPrompt = $derived(session?.state === 'waiting_input');

  // Subscribe to store changes for reactivity
  let _tick = $state(0);
  $effect(() => {
    const unsub = sessionStore.subscribe(() => { _tick++; });
    return unsub;
  });

  function handlePromptSubmit(text: string) {
    ws.sendPromptResponse(text, sessionId);
  }

  // Quick action shortcuts
  function sendKey(key: string) {
    ws.sendTerminalInput(key, sessionId);
  }
</script>

<div class="detail">
  <header>
    <button class="back" onclick={onback}>&larr;</button>
    <h1>{session?.cwd?.split('/').pop() || `Session ${sessionId}`}</h1>
    {#if session}
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
    {/if}
  </header>

  <TerminalView {sessionId} />

  <!-- Quick action bar -->
  <div class="actions">
    <button onclick={() => sendKey('\x03')}>Ctrl+C</button>
    <button onclick={() => sendKey('\t')}>Tab</button>
    <button onclick={() => sendKey('\x1b[A')}>↑</button>
    <button onclick={() => sendKey('\x1b[B')}>↓</button>
    <button onclick={() => sendKey('\x1b')}>Esc</button>
  </div>

  {#if showPrompt}
    <PromptOverlay {sessionId} onsubmit={handlePromptSubmit} />
  {/if}
</div>

<style>
  .detail {
    display: flex;
    flex-direction: column;
    height: 100dvh;
  }

  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 1rem;
    background: var(--card-bg);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  header h1 { font-size: 1rem; color: var(--accent); flex: 1; }
  .back {
    background: none;
    border: none;
    color: var(--accent);
    font-size: 1.2rem;
    cursor: pointer;
    padding: 0 0.5rem;
  }

  .status {
    font-size: 0.7rem;
    padding: 0.15rem 0.5rem;
    border-radius: 4px;
  }
  .status.running { background: var(--success); color: #000; }
  .status.waiting_input { background: var(--warn); color: #000; }
  .status.stopped { background: var(--danger); color: #fff; }
  .status.starting { background: var(--accent); color: #000; }

  .actions {
    display: flex;
    gap: 0;
    flex-shrink: 0;
    border-top: 1px solid var(--border);
    background: var(--card-bg);
  }
  .actions button {
    flex: 1;
    padding: 0.6rem;
    border: none;
    border-right: 1px solid var(--border);
    background: transparent;
    color: var(--fg);
    font-size: 0.8rem;
    cursor: pointer;
    font-family: monospace;
  }
  .actions button:last-child { border-right: none; }
  .actions button:active { background: var(--border); }
</style>
```

- [ ] **Step 3: 创建 PromptOverlay.svelte**

```svelte
<script lang="ts">
  import { sessionStore } from '../stores/sessions';

  let { sessionId, onsubmit }: { sessionId: number; onsubmit: (text: string) => void } = $props();
  let inputText = $state('');

  // Get prompt options from the latest prompt_request message
  // For now, provide basic Yes/No options; will be enhanced when we parse prompt data
  let options = ['Yes', 'No'];

  function handleSubmit() {
    if (inputText.trim()) {
      onsubmit(inputText.trim());
      inputText = '';
    }
  }

  function handleOption(opt: string) {
    onsubmit(opt);
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  }
</script>

<div class="overlay">
  <div class="prompt-bar">
    <div class="options">
      {#each options as opt}
        <button class="opt-btn" onclick={() => handleOption(opt)}>{opt}</button>
      {/each}
    </div>
    <div class="input-row">
      <input
        type="text"
        bind:value={inputText}
        onkeydown={handleKeydown}
        placeholder="Type a response..."
      />
      <button class="send-btn" onclick={handleSubmit}>Send</button>
    </div>
  </div>
</div>

<style>
  .overlay {
    position: absolute;
    bottom: 0;
    left: 0;
    right: 0;
    z-index: 20;
    padding-bottom: env(safe-area-inset-bottom, 0);
  }

  .prompt-bar {
    background: var(--card-bg);
    border-top: 2px solid var(--warn);
    padding: 0.75rem;
  }

  .options {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 0.5rem;
    flex-wrap: wrap;
  }

  .opt-btn {
    padding: 0.4rem 1rem;
    border: 1px solid var(--accent);
    border-radius: 20px;
    background: transparent;
    color: var(--accent);
    font-size: 0.85rem;
    cursor: pointer;
  }
  .opt-btn:active { background: var(--accent); color: #000; }

  .input-row {
    display: flex;
    gap: 0.5rem;
  }

  input {
    flex: 1;
    padding: 0.6rem 0.8rem;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--bg);
    color: var(--fg);
    font-size: 0.9rem;
  }
  input:focus { outline: none; border-color: var(--accent); }

  .send-btn {
    padding: 0.6rem 1rem;
    border: none;
    border-radius: 8px;
    background: var(--accent);
    color: #000;
    font-weight: 600;
    cursor: pointer;
  }
</style>
```

- [ ] **Step 4: 更新 App.svelte 集成 SessionDetail**

```svelte
<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { ws } from './lib/ws';
  import { onMount } from 'svelte';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);

  onMount(() => {
    ws.connect();
    return () => ws.disconnect();
  });

  function openSession(id: number) {
    selectedSessionId = id;
    currentView = 'detail';
  }

  function goBack() {
    currentView = 'list';
    selectedSessionId = null;
  }
</script>

<main>
  {#if currentView === 'list'}
    <header>
      <h1>Kite</h1>
    </header>
    <SessionList onselect={openSession} />
  {:else if selectedSessionId}
    <SessionDetail sessionId={selectedSessionId} onback={goBack} />
  {/if}
</main>

<style>
  header {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 1rem;
    background: var(--card-bg);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  header h1 { font-size: 1rem; color: var(--accent); }
  main {
    display: flex;
    flex-direction: column;
    height: 100dvh;
  }
</style>
```

- [ ] **Step 5: 验证构建**

Run: `cd web && npm run build`
Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add web/src/
git commit -m "feat: add TerminalView, SessionDetail, and PromptOverlay components"
```

---

### Task 13: 集成验证

**Files:** None (verification only)

- [ ] **Step 1: 后端构建和测试**

Run: `zig build 2>&1 && zig build test 2>&1`
Expected: BUILD SUCCESS, ALL TESTS PASS

- [ ] **Step 2: 前端构建**

Run: `cd web && npm run build`
Expected: BUILD SUCCESS, 产物在 web/dist/

- [ ] **Step 3: 端到端手动测试**

启动后端：
```bash
./zig-out/bin/kite start --no-auth --static-dir web/dist
```

在另一个终端创建 session：
```bash
./zig-out/bin/kite run
```

打开浏览器访问 `http://localhost:7890`，验证：
1. Session 列表显示卡片
2. 点击卡片进入终端
3. 终端可以输入和显示输出
4. 返回按钮回到列表
5. 快捷操作栏按钮可用

- [ ] **Step 4: Vite dev server 测试**

```bash
cd web && npm run dev
```

打开 `http://localhost:5173`，验证 proxy 到后端正常工作。

- [ ] **Step 5: Final commit（如有遗漏修复）**

```bash
git add -A
git commit -m "feat: complete M4 - frontend/backend separation"
```
