# M1: Daemon 化 + UserPromptSubmit 核心交互 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Kite 从前台单进程改造为后台 daemon 服务，实现"Claude 等待输入 → 手机通知 → 快速回复"的核心交互链路。

**Architecture:** `kite start` 启动 daemon 进程（HTTP/WS 服务 + IPC 监听），`kite run` 通过 HTTP API 请求 daemon 创建 PTY session。Hook 事件（特别是 Stop）触发 session 状态变为 `waiting_input`，通过 WebSocket 推送给客户端。客户端展示状态卡片和 UserPromptSubmit 交互界面。

**Tech Stack:** Zig 0.15.2, std.http.Server, xterm.js 5.5.0, WebSocket

---

## 文件结构

### 新建文件
| 文件 | 职责 |
|------|------|
| `src/daemon.zig` | PID 文件管理、daemon 状态查询 |
| `src/session_manager.zig` | Session 生命周期管理、PTY 创建/销毁、I/O relay 线程 |
| `src/prompt_parser.zig` | 从 Hook payload 和终端输出中提取提示摘要和选项 |

### 修改文件
| 文件 | 变更内容 |
|------|----------|
| `src/session.zig` | 新增 `waiting_input` 状态，新增 `prompt_context` 字段 |
| `src/hooks.zig` | 新增 `UserPromptSubmit` 和 `Stop` 处理逻辑，hook 配置更新 |
| `src/protocol.zig` | 新增 `prompt_request`、`prompt_response`、`session_state_change` 消息类型 |
| `src/http.zig` | 新增 `POST /api/sessions` 端点，`Server` 改为持有 `SessionManager` 指针 |
| `src/ws.zig` | `WsBroadcaster` 无需变更（M1 只有单 session，广播所有消息） |
| `src/web.zig` | 重写 UI：状态卡片 + UserPromptSubmit 交互 + 终端模式切换 |
| `src/main.zig` | 新增 `run` 命令，`start` 改为 daemon 模式，主循环移入 SessionManager |
| `src/root.zig` | 导出新增模块 |

---

## Task 1: Session 状态机扩展

**Files:**
- Modify: `src/session.zig:54-68` (SessionState, Session struct)
- Test: `src/session.zig` (底部 test block)

- [ ] **Step 1: 编写新状态的测试**

在 `src/session.zig` 底部添加测试：

```zig
test "session state transitions" {
    const allocator = std.testing.allocator;
    var s = try Session.init(allocator, 1);
    defer s.deinit();

    try std.testing.expectEqual(SessionState.starting, s.state);

    s.state = .running;
    try std.testing.expectEqual(SessionState.running, s.state);

    s.setWaitingInput("What would you like to do?", &.{ "Continue", "Stop" });
    try std.testing.expectEqual(SessionState.waiting_input, s.state);
    try std.testing.expectEqualStrings("What would you like to do?", s.prompt_context.?.summary);
    try std.testing.expectEqual(@as(usize, 2), s.prompt_context.?.options.len);

    s.clearPromptContext();
    try std.testing.expectEqual(SessionState.running, s.state);
    try std.testing.expect(s.prompt_context == null);
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `zig build test 2>&1 | head -30`
Expected: 编译错误，`waiting_input` 和 `setWaitingInput` 不存在

- [ ] **Step 3: 实现状态机扩展**

修改 `src/session.zig`：

1. 更新 `SessionState` 枚举：
```zig
pub const SessionState = enum {
    starting,
    running,
    waiting_input,
    stopped,
};
```

2. 新增 `PromptContext` 结构体（在 `SessionState` 之后）：
```zig
pub const PromptContext = struct {
    summary: []const u8,
    options: []const []const u8,
    raw_json: []const u8 = "",
};
```

3. 在 `Session` struct 中新增字段（在 `created_at` 之后）：
```zig
    prompt_context: ?PromptContext = null,
    command: []const u8 = "",
    cwd: []const u8 = "",
```

4. 新增方法（在 `addHookEvent` 之后）：
```zig
    pub fn setWaitingInput(self: *Session, summary: []const u8, options: []const []const u8) void {
        self.state = .waiting_input;
        self.prompt_context = .{
            .summary = summary,
            .options = options,
        };
    }

    pub fn clearPromptContext(self: *Session) void {
        self.state = .running;
        self.prompt_context = null;
    }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 5: 提交**

```bash
git add src/session.zig
git commit -m "feat(session): add waiting_input state and prompt context"
```

---

## Task 2: Prompt 解析器

**Files:**
- Create: `src/prompt_parser.zig`
- Modify: `src/root.zig` (添加导出)

- [ ] **Step 1: 创建文件并编写测试**

创建 `src/prompt_parser.zig`：

```zig
const std = @import("std");

pub const ParsedPrompt = struct {
    summary: []const u8,
    options: []const []const u8,
};

/// 从 Claude Code 的 Stop hook payload 中提取提示摘要。
/// stop_reason 为 "end_turn" 表示 Claude 完成处理等待下一轮输入。
pub fn isWaitingForInput(stop_reason: []const u8) bool {
    return std.mem.eql(u8, stop_reason, "end_turn");
}

/// 从终端输出的最后几行中提取选项。
/// 识别模式如：(y)es/(n)o、[Y/n]、1. xxx 2. xxx 等。
pub fn extractOptions(allocator: std.mem.Allocator, terminal_tail: []const u8) ![]const []const u8 {
    var options: std.ArrayList([]const u8) = .empty;
    errdefer options.deinit(allocator);

    // 匹配 (y)es/(n)o 风格
    if (containsYesNo(terminal_tail)) {
        try options.append(allocator, "Yes");
        try options.append(allocator, "No");
        return options.toOwnedSlice(allocator);
    }

    // 匹配数字列表: "1. xxx\n2. xxx"
    var lines = std.mem.splitScalar(u8, terminal_tail, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 3 and trimmed[0] >= '1' and trimmed[0] <= '9' and (trimmed[1] == '.' or trimmed[1] == ')')) {
            const option_text = std.mem.trim(u8, trimmed[2..], " ");
            if (option_text.len > 0) {
                try options.append(allocator, option_text);
            }
        }
    }

    return options.toOwnedSlice(allocator);
}

/// 从终端输出最后部分提取摘要（最后的非空行，最多 500 字节）
pub fn extractSummary(terminal_tail: []const u8) []const u8 {
    if (terminal_tail.len == 0) return "";

    // 找最后一个有意义的内容块（跳过尾部空行）
    var end = terminal_tail.len;
    while (end > 0 and (terminal_tail[end - 1] == '\n' or terminal_tail[end - 1] == '\r' or terminal_tail[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return "";

    // 往前找最多 500 字节
    const max_len: usize = 500;
    const start = if (end > max_len) end - max_len else 0;

    return terminal_tail[start..end];
}

fn containsYesNo(text: []const u8) bool {
    // 检查常见的 yes/no 模式
    const patterns = [_][]const u8{
        "(y/n)",
        "(Y/n)",
        "(y/N)",
        "[y/n]",
        "[Y/n]",
        "[y/N]",
        "(yes/no)",
        "Yes/No",
    };
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, text, pattern) != null) return true;
    }
    return false;
}

test "isWaitingForInput" {
    try std.testing.expect(isWaitingForInput("end_turn"));
    try std.testing.expect(!isWaitingForInput("error"));
    try std.testing.expect(!isWaitingForInput(""));
}

test "extractOptions yes/no" {
    const allocator = std.testing.allocator;
    const options = try extractOptions(allocator, "Do you want to continue? (y/n)");
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("Yes", options[0]);
    try std.testing.expectEqualStrings("No", options[1]);
}

test "extractOptions numbered list" {
    const allocator = std.testing.allocator;
    const text = "Choose an option:\n1. Create new file\n2. Edit existing\n3. Delete";
    const options = try extractOptions(allocator, text);
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 3), options.len);
    try std.testing.expectEqualStrings("Create new file", options[0]);
    try std.testing.expectEqualStrings("Edit existing", options[1]);
    try std.testing.expectEqualStrings("Delete", options[2]);
}

test "extractOptions no options" {
    const allocator = std.testing.allocator;
    const options = try extractOptions(allocator, "Just some regular text output");
    defer allocator.free(options);
    try std.testing.expectEqual(@as(usize, 0), options.len);
}

test "extractSummary" {
    const summary = extractSummary("Hello\nWhat would you like to do?\n\n");
    try std.testing.expectEqualStrings("Hello\nWhat would you like to do?", summary);
}

test "extractSummary empty" {
    const summary = extractSummary("");
    try std.testing.expectEqualStrings("", summary);
}
```

- [ ] **Step 2: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass（新文件需要先被 root.zig 引用才能跑测试）

- [ ] **Step 3: 更新 root.zig 导出**

在 `src/root.zig` 添加：
```zig
pub const prompt_parser = @import("prompt_parser.zig");
```

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 5: 提交**

```bash
git add src/prompt_parser.zig src/root.zig
git commit -m "feat: add prompt parser for extracting options and summaries"
```

---

## Task 3: Daemon 模块

**Files:**
- Create: `src/daemon.zig`
- Modify: `src/root.zig` (添加导出)

- [ ] **Step 1: 创建 daemon.zig 并编写测试**

创建 `src/daemon.zig`：

```zig
const std = @import("std");
const posix = std.posix;

pub const PID_FILE_PATH = "/tmp/kite.pid";

pub const DaemonError = error{
    AlreadyRunning,
    WritePidFailed,
};

/// 检查 daemon 是否正在运行（通过 PID 文件和进程存活检测）
pub fn isRunning() bool {
    const pid = readPidFile() orelse return false;
    // 发送信号 0 检查进程是否存在
    posix.kill(pid, 0) catch return false;
    return true;
}

/// 写入 PID 文件
pub fn writePidFile() !void {
    const pid = std.c.getpid();
    const file = std.fs.createFileAbsolute(PID_FILE_PATH, .{ .truncate = true }) catch
        return error.WritePidFailed;
    defer file.close();
    var buf: [20]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return error.WritePidFailed;
    file.writeAll(pid_str) catch return error.WritePidFailed;
}

/// 删除 PID 文件
pub fn removePidFile() void {
    std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};
}

/// 读取 PID 文件中的 PID
pub fn readPidFile() ?posix.pid_t {
    const file = std.fs.openFileAbsolute(PID_FILE_PATH, .{}) catch return null;
    defer file.close();
    var buf: [20]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    if (n == 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    return std.fmt.parseInt(posix.pid_t, trimmed, 10) catch null;
}

test "pid file round trip" {
    // Clean up any existing file
    std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};
    defer std.fs.deleteFileAbsolute(PID_FILE_PATH) catch {};

    try writePidFile();
    const pid = readPidFile();
    try std.testing.expect(pid != null);
    try std.testing.expectEqual(std.c.getpid(), pid.?);

    // isRunning should return true for our own process
    try std.testing.expect(isRunning());

    removePidFile();
    try std.testing.expect(!isRunning());
}
```

- [ ] **Step 2: 更新 root.zig**

在 `src/root.zig` 添加：
```zig
pub const daemon = @import("daemon.zig");
```

- [ ] **Step 3: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 4: 提交**

```bash
git add src/daemon.zig src/root.zig
git commit -m "feat: add daemon module with PID file management"
```

---

## Task 4: SessionManager

**Files:**
- Create: `src/session_manager.zig`
- Modify: `src/root.zig` (添加导出)

SessionManager 负责：创建/销毁 PTY session，为每个 session 运行 I/O relay 线程，将终端输出广播给客户端。

- [ ] **Step 1: 编写 SessionManager 测试**

创建 `src/session_manager.zig`，先写测试：

```zig
const std = @import("std");
const posix = std.posix;
const Pty = @import("pty.zig").Pty;
const Session = @import("session.zig").Session;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const protocol = @import("protocol.zig");
const prompt_parser = @import("prompt_parser.zig");

pub const SessionManager = struct {
    sessions: std.AutoHashMap(u64, *ManagedSession),
    allocator: std.mem.Allocator,
    broadcaster: *WsBroadcaster,
    next_id: u64 = 1,
    mutex: std.Thread.Mutex = .{},

    pub const ManagedSession = struct {
        session: Session,
        pty: Pty,
        relay_thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    };

    pub const CreateOptions = struct {
        command: []const u8 = "claude",
        cwd: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, broadcaster: *WsBroadcaster) SessionManager {
        return .{
            .sessions = std.AutoHashMap(u64, *ManagedSession).init(allocator),
            .allocator = allocator,
            .broadcaster = broadcaster,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |ms_ptr| {
            const ms = ms_ptr.*;
            ms.running.store(false, .release);
            ms.pty.close();
            ms.session.deinit();
            self.allocator.destroy(ms);
        }
        self.sessions.deinit();
    }

    /// 创建新 session，spawn PTY 子进程，启动 I/O relay 线程
    pub fn createSession(self: *SessionManager, opts: CreateOptions) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var ms = try self.allocator.create(ManagedSession);
        errdefer self.allocator.destroy(ms);

        ms.* = .{
            .session = try Session.init(self.allocator, id),
            .pty = try Pty.open(),
        };
        ms.session.state = .starting;
        ms.session.command = opts.command;
        ms.session.cwd = opts.cwd;

        // Spawn child process
        const cmd_z = try self.allocator.dupeZ(u8, opts.command);
        defer self.allocator.free(cmd_z);
        const argv = [_]?[*:0]const u8{ cmd_z.ptr, null };
        try ms.pty.spawn(&argv, null);
        ms.session.state = .running;

        try self.sessions.put(id, ms);

        // Start I/O relay thread
        ms.relay_thread = try std.Thread.spawn(.{}, ioRelay, .{ self, ms });

        return id;
    }

    /// 销毁 session
    pub fn destroySession(self: *SessionManager, id: u64) void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        _ = self.sessions.remove(id);
        self.mutex.unlock();

        ms.running.store(false, .release);
        ms.pty.close();
        ms.session.deinit();
        self.allocator.destroy(ms);
    }

    /// 获取 session（只读）
    pub fn getSession(self: *SessionManager, id: u64) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sessions.get(id)) |ms| {
            return &ms.session;
        }
        return null;
    }

    /// 获取 ManagedSession
    pub fn getManagedSession(self: *SessionManager, id: u64) ?*ManagedSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(id);
    }

    /// 向 session 的 PTY 写入数据
    pub fn writeToSession(self: *SessionManager, id: u64, data: []const u8) !void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        try ms.pty.writeMaster(data);
    }

    /// 设置 session 的终端窗口大小
    pub fn resizeSession(self: *SessionManager, id: u64, rows: u16, cols: u16) void {
        self.mutex.lock();
        const ms = self.sessions.get(id) orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        ms.pty.setWindowSize(rows, cols);
    }

    /// 列出所有 session 信息
    pub fn listSessions(self: *SessionManager, allocator: std.mem.Allocator) ![]SessionInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list: std.ArrayList(SessionInfo) = .empty;
        errdefer list.deinit(allocator);

        var it = self.sessions.valueIterator();
        while (it.next()) |ms_ptr| {
            const ms = ms_ptr.*;
            try list.append(allocator, .{
                .id = ms.session.id,
                .state = ms.session.state,
                .command = ms.session.command,
                .cwd = ms.session.cwd,
            });
        }

        return list.toOwnedSlice(allocator);
    }

    /// 处理 Hook 事件，更新 session 状态
    pub fn handleHookEvent(self: *SessionManager, session_id: u64, event_name: []const u8, raw_json: []const u8) void {
        const session = self.getSession(session_id) orelse return;

        if (std.mem.eql(u8, event_name, "Stop")) {
            // 解析 stop_reason
            const parsed = std.json.parseFromSlice(StopPayload, self.allocator, raw_json, .{
                .ignore_unknown_fields = true,
            }) catch return;
            defer parsed.deinit();

            if (prompt_parser.isWaitingForInput(parsed.value.stop_reason)) {
                // 从终端 buffer 提取摘要和选项
                const tail = self.getTerminalTail(session);
                const summary = prompt_parser.extractSummary(tail);
                const options = prompt_parser.extractOptions(self.allocator, tail) catch &.{};

                session.setWaitingInput(summary, options);

                // 广播 prompt_request
                const msg = protocol.encodePromptRequest(self.allocator, session.id, summary, options) catch return;
                defer self.allocator.free(msg);
                self.broadcaster.broadcast(msg);
            }
        } else if (std.mem.eql(u8, event_name, "SessionStart")) {
            session.state = .running;
            session.clearPromptContext();
        }

        // 广播状态变更
        const state_msg = protocol.encodeSessionStateChange(self.allocator, session.id, session.state) catch return;
        defer self.allocator.free(state_msg);
        self.broadcaster.broadcast(state_msg);
    }

    fn getTerminalTail(self: *SessionManager, session: *Session) []const u8 {
        _ = self;
        const sl = session.terminal_buffer.slice();
        // 返回最后部分（优先 second，如果为空则用 first）
        if (sl.second.len > 0) return sl.second;
        return sl.first;
    }

    /// I/O relay 线程：从 PTY 读取输出，写入 session buffer 并广播
    fn ioRelay(self: *SessionManager, ms: *ManagedSession) void {
        var buf: [4096]u8 = undefined;

        while (ms.running.load(.acquire) and ms.pty.isChildAlive()) {
            var fds = [1]posix.pollfd{
                .{ .fd = ms.pty.master, .events = posix.POLL.IN, .revents = 0 },
            };
            const ready = posix.poll(&fds, 100) catch break;
            if (ready == 0) continue;

            if (fds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(ms.pty.master, &buf) catch break;
                if (n == 0) break;
                const data = buf[0..n];

                ms.session.appendTerminalOutput(data);

                const msg = protocol.encodeTerminalOutput(self.allocator, data) catch continue;
                defer self.allocator.free(msg);
                self.broadcaster.broadcast(msg);
            }
            if (fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) break;
        }

        // 子进程退出，更新状态
        ms.session.state = .stopped;
        const status_msg = protocol.encodeSessionStateChange(self.allocator, ms.session.id, .stopped) catch return;
        defer self.allocator.free(status_msg);
        self.broadcaster.broadcast(status_msg);
    }
};

pub const SessionInfo = struct {
    id: u64,
    state: @import("session.zig").SessionState,
    command: []const u8,
    cwd: []const u8,
};

const StopPayload = struct {
    stop_reason: []const u8 = "",
};

test "session manager init/deinit" {
    const allocator = std.testing.allocator;
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var mgr = SessionManager.init(allocator, &broadcaster);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.sessions.count());
}
```

- [ ] **Step 2: 更新 root.zig**

在 `src/root.zig` 添加：
```zig
pub const SessionManager = @import("session_manager.zig").SessionManager;
```

- [ ] **Step 3: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 4: 提交**

```bash
git add src/session_manager.zig src/root.zig
git commit -m "feat: add SessionManager for PTY session lifecycle management"
```

---

## Task 5: Protocol 扩展

**Files:**
- Modify: `src/protocol.zig`

新增三种消息类型：
- `prompt_request`：daemon → client，Claude 等待输入时推送
- `prompt_response`：client → daemon，用户回复
- `session_state_change`：daemon → client，状态变更通知

- [ ] **Step 1: 编写测试**

在 `src/protocol.zig` 底部添加测试：

```zig
test "encodePromptRequest" {
    const allocator = std.testing.allocator;
    const options = [_][]const u8{ "Yes", "No" };
    const msg = try encodePromptRequest(allocator, 1, "Continue?", &options);
    defer allocator.free(msg);
    // 验证是合法 JSON
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `zig build test 2>&1 | head -20`
Expected: 编译错误，函数不存在

- [ ] **Step 3: 实现新消息类型**

在 `src/protocol.zig` 的 `encodeAuthResult` 函数之后添加：

```zig
pub fn encodePromptRequest(allocator: std.mem.Allocator, session_id: u64, summary: []const u8, options: []const []const u8) ![]u8 {
    const escaped_summary = try jsonEscapeAlloc(allocator, summary);
    defer allocator.free(escaped_summary);

    // 构建 options JSON 数组
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
```

同时更新 `ClientMessage` 结构体，新增 `prompt_response` 所需字段：

```zig
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 5: 提交**

```bash
git add src/protocol.zig
git commit -m "feat(protocol): add prompt_request and session_state_change message types"
```

---

## Task 6: Hook 系统更新

**Files:**
- Modify: `src/hooks.zig`

- [ ] **Step 1: 更新 HookEventType 枚举**

在 `src/hooks.zig` 的 `HookEventType` 枚举中添加 `UserPromptSubmit`：

```zig
pub const HookEventType = enum {
    SessionStart,
    PreToolUse,
    PostToolUse,
    Notification,
    Stop,
    UserPromptSubmit,

    pub fn fromString(s: []const u8) ?HookEventType {
        const map = std.StaticStringMap(HookEventType).initComptime(.{
            .{ "SessionStart", .SessionStart },
            .{ "PreToolUse", .PreToolUse },
            .{ "PostToolUse", .PostToolUse },
            .{ "Notification", .Notification },
            .{ "Stop", .Stop },
            .{ "UserPromptSubmit", .UserPromptSubmit },
        });
        return map.get(s);
    }

    pub fn toString(self: HookEventType) []const u8 {
        return switch (self) {
            .SessionStart => "SessionStart",
            .PreToolUse => "PreToolUse",
            .PostToolUse => "PostToolUse",
            .Notification => "Notification",
            .Stop => "Stop",
            .UserPromptSubmit => "UserPromptSubmit",
        };
    }
};
```

- [ ] **Step 2: 更新 hook 配置生成**

修改 `ClaudeCodeConfig.generateHooksConfig`，添加 `UserPromptSubmit` 和 `Stop` 的配置：

```zig
    pub fn generateHooksConfig(allocator: std.mem.Allocator, kite_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "hooks": {{
            \\    "PreToolUse": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event PreToolUse"
            \\    }}],
            \\    "PostToolUse": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event PostToolUse",
            \\      "timeout": 0
            \\    }}],
            \\    "Notification": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event Notification",
            \\      "timeout": 0
            \\    }}],
            \\    "SessionStart": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event SessionStart"
            \\    }}],
            \\    "Stop": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event Stop",
            \\      "timeout": 0
            \\    }}],
            \\    "UserPromptSubmit": [{{
            \\      "type": "command",
            \\      "command": "{s} hook --event UserPromptSubmit"
            \\    }}]
            \\  }}
            \\}}
        , .{ kite_path, kite_path, kite_path, kite_path, kite_path, kite_path });
    }
```

- [ ] **Step 3: 运行测试确认通过**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass

- [ ] **Step 4: 提交**

```bash
git add src/hooks.zig
git commit -m "feat(hooks): add UserPromptSubmit event type and hook config"
```

---

## Task 7: HTTP Server 重构

**Files:**
- Modify: `src/http.zig`

Server 需要改为持有 SessionManager 指针，新增 session 创建 API。

- [ ] **Step 1: 重构 Server 结构体**

修改 `src/http.zig` 的 `Server` struct，将 `session` 字段替换为 `session_manager`：

```zig
pub const Server = struct {
    allocator: std.mem.Allocator,
    address: net.Address,
    auth: *auth_mod.Auth,
    broadcaster: *ws_mod.WsBroadcaster,
    session_manager: *SessionManager,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

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
```

需要添加 import：
```zig
const SessionManager = @import("session_manager.zig").SessionManager;
```

- [ ] **Step 2: 更新路由，添加 session 创建端点**

更新 `handleConnection` 方法，添加新路由：

```zig
    fn handleConnection(self: *Server, stream: net.Stream) void {
        defer stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var net_reader = stream.reader(&read_buf);
        var net_writer = stream.writer(&write_buf);

        var http_server = http.Server.init(net_reader.interface(), &net_writer.interface);
        var head = http_server.receiveHead() catch return;

        const path = head.head.target;

        if (std.mem.startsWith(u8, path, "/ws")) {
            self.handleWebSocket(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/auth") and head.head.method == .POST) {
            self.handleAuth(&head) catch {};
            return;
        }

        if (std.mem.eql(u8, path, "/api/sessions") and head.head.method == .POST) {
            self.handleCreateSession(&head) catch {};
            return;
        }

        if (std.mem.startsWith(u8, path, "/api/sessions")) {
            self.handleSessionsApi(&head) catch {};
            return;
        }

        self.serveStaticFile(&head, path) catch {};
    }
```

- [ ] **Step 3: 实现 handleCreateSession**

```zig
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
        };
        const parsed = std.json.parseFromSlice(CreateReq, self.allocator, body_slice, .{
            .ignore_unknown_fields = true,
        }) catch {
            try head.respond("{\"error\":\"invalid json\"}", .{
                .status = .bad_request,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        };
        defer parsed.deinit();

        const session_id = self.session_manager.createSession(.{
            .command = parsed.value.command,
            .cwd = parsed.value.cwd,
        }) catch {
            try head.respond("{\"error\":\"failed to create session\"}", .{
                .status = .internal_server_error,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        };

        const response = std.fmt.allocPrint(self.allocator, "{{\"session_id\":{d}}}", .{session_id}) catch return;
        defer self.allocator.free(response);
        try head.respond(response, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
    }
```

- [ ] **Step 4: 更新 handleSessionsApi（替换原 handleSessionApi）**

```zig
    fn handleSessionsApi(self: *Server, head: *http.Server.Request) !void {
        const path = head.head.target;

        // GET /api/sessions — 列出所有
        if (std.mem.eql(u8, path, "/api/sessions")) {
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
                try json_buf.appendSlice(self.allocator, entry);
            }
            try json_buf.appendSlice(self.allocator, "]");
            try head.respond(json_buf.items, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
            return;
        }

        // 单 session 操作: /api/sessions/<id>
        // M1 阶段简化：返回第一个 session 的状态
        const sessions = self.session_manager.listSessions(self.allocator) catch return;
        defer self.allocator.free(sessions);
        if (sessions.len > 0) {
            const s = sessions[0];
            const state_str = switch (s.state) {
                .starting => "starting",
                .running => "running",
                .waiting_input => "waiting_input",
                .stopped => "stopped",
            };
            const response = std.fmt.allocPrint(self.allocator,
                \\{{"id":{d},"state":"{s}","command":"{s}","cwd":"{s}"}}
            , .{ s.id, state_str, s.command, s.cwd }) catch return;
            defer self.allocator.free(response);
            try head.respond(response, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        } else {
            try head.respond("{\"error\":\"no sessions\"}", .{
                .status = .not_found,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
            });
        }
    }
```

- [ ] **Step 5: 更新 WebSocket 处理（支持 prompt_response 和 session_id）**

修改 `handleWebSocket` 中的消息处理部分，在 `resize` 处理之后添加：

```zig
            } else if (std.mem.eql(u8, msg.@"type", "prompt_response")) {
                if (msg.text) |text| {
                    // 将用户输入写入 PTY（加换行符模拟回车）
                    const sid = msg.session_id orelse 1;
                    var input_buf: [4097]u8 = undefined;
                    if (text.len < input_buf.len - 1) {
                        @memcpy(input_buf[0..text.len], text);
                        input_buf[text.len] = '\n';
                        self.session_manager.writeToSession(sid, input_buf[0 .. text.len + 1]) catch {};
                    }
                }
```

同时更新 WebSocket 连接初始化时发送历史输出的逻辑（使用 session_manager 获取 session）：

```zig
        // Send initial terminal history for the first session
        if (self.session_manager.getSession(1)) |session| {
            const history = session.terminal_buffer.slice();
            if (history.first.len > 0) {
                const msg_out = protocol.encodeTerminalOutput(self.allocator, history.first) catch null;
                if (msg_out) |m| {
                    defer self.allocator.free(m);
                    client.send(m);
                }
            }
            if (history.second.len > 0) {
                const msg_out = protocol.encodeTerminalOutput(self.allocator, history.second) catch null;
                if (msg_out) |m| {
                    defer self.allocator.free(m);
                    client.send(m);
                }
            }
        }
```

删除旧的 `on_terminal_input` 和 `on_resize` 字段及相关代码，用 `session_manager.writeToSession` 和 `session_manager.resizeSession` 替代。

- [ ] **Step 6: 运行构建确认编译通过**

Run: `zig build 2>&1 | head -30`
Expected: 编译可能因 main.zig 还未更新而失败，但 http.zig 本身无语法错误

- [ ] **Step 7: 提交**

```bash
git add src/http.zig
git commit -m "feat(http): restructure server for SessionManager, add session creation API"
```

---

## Task 8: Main 重构 — Daemon 模式

**Files:**
- Modify: `src/main.zig`

将 `kite start` 改为 daemon 模式（启动 HTTP 服务 + IPC 监听，不直接 spawn PTY）。
新增 `kite run` 命令通过 HTTP API 请求 daemon 创建 session。

- [ ] **Step 1: 更新 Command 枚举和 imports**

```zig
const std = @import("std");
const posix = std.posix;
const Session = @import("session.zig").Session;
const Auth = @import("auth.zig").Auth;
const auth_mod = @import("auth.zig");
const HttpServer = @import("http.zig").Server;
const WsBroadcaster = @import("ws.zig").WsBroadcaster;
const hooks = @import("hooks.zig");
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");
const daemon = @import("daemon.zig");
const SessionManager = @import("session_manager.zig").SessionManager;

const Config = struct {
    port: u16 = 7890,
    bind: []const u8 = "0.0.0.0",
    command: []const u8 = "claude",
};

const Command = enum {
    start,
    run,
    hook,
    setup,
    status,
    help,
};
```

更新 `parseCommand`：
```zig
fn parseCommand(arg: []const u8) ?Command {
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "start", .start },
        .{ "run", .run },
        .{ "hook", .hook },
        .{ "setup", .setup },
        .{ "status", .status },
        .{ "help", .help },
        .{ "--help", .help },
        .{ "-h", .help },
    });
    return map.get(arg);
}
```

更新 `main` 的 switch：
```zig
    switch (cmd) {
        .start => try runStart(allocator, args[2..]),
        .run => try runRun(allocator, args[2..]),
        .hook => try runHook(allocator, args[2..]),
        .setup => try runSetup(allocator),
        .status => try runStatus(),
        .help => printUsage(),
    }
```

- [ ] **Step 2: 重写 runStart 为 daemon 模式**

删除旧的 `runStart` 函数、`global_pty`、`sigwinch_received`、`onTerminalInput`、`onResize`、`handleSigwinch`、`syncWindowSize`。

新的 `runStart`：

```zig
fn runStart(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 7890;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bind") and i + 1 < args.len) {
            config.bind = args[i + 1];
            i += 1;
        }
    }

    // 检查是否已经运行
    if (daemon.isRunning()) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write("kite daemon is already running.\n") catch {};
        return;
    }

    // 写入 PID 文件
    try daemon.writePidFile();
    defer daemon.removePidFile();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // 初始化认证
    var auth = Auth.init();
    const setup_hex = auth.getSetupTokenHex();

    try stdout.print("\n  kite daemon started\n", .{});
    try stdout.print("  ====================\n\n", .{});
    try stdout.print("  Server: http://{s}:{d}\n", .{ config.bind, config.port });

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/?token={s}", .{ config.bind, config.port, setup_hex });
    defer allocator.free(url);
    try auth_mod.renderQrCode(stdout, url);
    try stdout.print("  Use 'kite run' to create a session.\n\n", .{});
    try stdout.flush();

    // 初始化 broadcaster 和 session manager
    var broadcaster = WsBroadcaster.init(allocator);
    defer broadcaster.deinit();

    var session_manager = SessionManager.init(allocator, &broadcaster);
    defer session_manager.deinit();

    // 启动 HTTP 服务器
    var http_server = try HttpServer.init(
        allocator,
        config.bind,
        config.port,
        &auth,
        &broadcaster,
        &session_manager,
    );
    const server_thread = try std.Thread.spawn(.{}, HttpServer.run, .{&http_server});
    _ = server_thread;

    // 启动 IPC 监听
    const ipc_thread = try std.Thread.spawn(.{}, runIpcListener, .{ allocator, &broadcaster, &session_manager });
    _ = ipc_thread;

    // Daemon 主循环：等待信号退出
    // 简单方案：阻塞在 stdin 读取（Ctrl+C 终止）
    try stdout.print("  Press Ctrl+C to stop the daemon.\n", .{});
    try stdout.flush();

    // 等待退出信号
    var sig_buf: [1]u8 = undefined;
    _ = posix.read(posix.STDIN_FILENO, &sig_buf) catch {};

    http_server.stop();
}
```

- [ ] **Step 3: 实现 runRun 命令**

```zig
fn runRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var config = Config{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmd") and i + 1 < args.len) {
            config.command = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = std.fmt.parseInt(u16, args[i + 1], 10) catch 7890;
            i += 1;
        }
    }

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    // 通过 HTTP API 请求 daemon 创建 session
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{config.port});
    defer allocator.free(url);

    const address = try std.net.Address.parseIp("127.0.0.1", config.port);
    const stream = std.net.tcpConnectToAddress(address) catch {
        try stdout.print("Cannot connect to kite daemon. Is it running? (kite start)\n", .{});
        try stdout.flush();
        return;
    };
    defer stream.close();

    // 构建 HTTP 请求
    const body = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{config.command});
    defer allocator.free(body);

    const request = try std.fmt.allocPrint(allocator,
        "POST /api/sessions HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ config.port, body.len, body },
    );
    defer allocator.free(request);

    stream.writeAll(request) catch {
        try stdout.print("Failed to send request to daemon.\n", .{});
        try stdout.flush();
        return;
    };

    // 读取响应
    var response_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < response_buf.len) {
        const n = stream.read(response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total > 0) {
        // 查找 HTTP body（双换行后）
        const response = response_buf[0..total];
        if (std.mem.indexOf(u8, response, "\r\n\r\n")) |body_start| {
            try stdout.print("  {s}\n", .{response[body_start + 4 ..]});
        } else {
            try stdout.print("  Session created.\n", .{});
        }
    } else {
        try stdout.print("  Session created.\n", .{});
    }
    try stdout.flush();
}
```

- [ ] **Step 4: 更新 IPC 监听器以支持 SessionManager**

```zig
fn runIpcListener(allocator: std.mem.Allocator, broadcaster: *WsBroadcaster, session_manager: *SessionManager) void {
    std.fs.deleteFileAbsolute(hooks.IPC_SOCKET_PATH) catch {};

    const server = std.net.Address.initUnix(hooks.IPC_SOCKET_PATH) catch return;
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(sock);

    posix.bind(sock, &server.any, server.getOsSockLen()) catch return;
    posix.listen(sock, 16) catch return;

    while (true) {
        const conn = posix.accept(sock, null, null, posix.SOCK.CLOEXEC) catch continue;
        handleIpcConnection(allocator, conn, broadcaster, session_manager);
        posix.close(conn);
    }
}

fn handleIpcConnection(allocator: std.mem.Allocator, conn: posix.fd_t, broadcaster: *WsBroadcaster, session_manager: *SessionManager) void {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;

    while (total < buf.len) {
        const n = posix.read(conn, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    if (total == 0) return;

    const data = buf[0..total];

    var lines = std.mem.splitScalar(u8, data, '\n');
    const event_name = lines.next() orelse return;
    _ = lines.next(); // length
    const rest = lines.rest();

    var tool_name: []const u8 = "";
    var session_id: u64 = 1; // M1 默认 session 1
    if (std.json.parseFromSlice(hooks.HookInput, allocator, rest, .{ .ignore_unknown_fields = true })) |parsed| {
        if (parsed.value.tool_name) |t| tool_name = t;
        if (parsed.value.session_id.len > 0) {
            session_id = std.fmt.parseInt(u64, parsed.value.session_id, 10) catch 1;
        }
        defer parsed.deinit();
    } else |_| {}

    // 广播 hook 事件
    const msg = protocol.encodeHookEvent(allocator, event_name, tool_name, rest) catch return;
    defer allocator.free(msg);
    broadcaster.broadcast(msg);

    // 让 SessionManager 处理状态更新
    session_manager.handleHookEvent(session_id, event_name, rest);

    if (std.mem.eql(u8, event_name, "PreToolUse")) {
        _ = posix.write(conn, "{}") catch {};
    }
}
```

- [ ] **Step 5: 更新 printUsage**

```zig
fn printUsage() void {
    const stdout_file = std.fs.File.stdout();
    _ = stdout_file.write(
        \\
        \\kite - AI Coding Assistant Remote Controller
        \\
        \\Usage:
        \\  kite start [options]    Start the kite daemon
        \\  kite run [options]      Create a new session in the daemon
        \\  kite hook --event <E>   Handle a Claude Code hook event (internal)
        \\  kite setup              Show Claude Code hooks configuration
        \\  kite status             Check if kite daemon is running
        \\  kite help               Show this help
        \\
        \\Options for 'start':
        \\  --port <PORT>   Server port (default: 7890)
        \\  --bind <ADDR>   Bind address (default: 0.0.0.0)
        \\
        \\Options for 'run':
        \\  --cmd <CMD>     Command to run (default: claude)
        \\  --port <PORT>   Daemon port (default: 7890)
        \\
    ) catch {};
}
```

- [ ] **Step 6: 运行构建**

Run: `zig build 2>&1 | head -30`
Expected: 编译通过

- [ ] **Step 7: 运行测试**

Run: `zig build test 2>&1 | head -30`
Expected: All tests pass

- [ ] **Step 8: 提交**

```bash
git add src/main.zig
git commit -m "feat(main): restructure for daemon mode with run command"
```

---

## Task 9: Web UI 重写

**Files:**
- Modify: `src/web.zig`

重写 Web UI，实现三个视图：
1. 状态卡片（默认）—— 显示 session 状态
2. UserPromptSubmit 交互 —— 摘要 + 选项按钮 + 输入框
3. 终端模式 —— 完整 xterm.js

- [ ] **Step 1: 重写 web.zig**

替换 `src/web.zig` 的全部内容：

```zig
pub const index_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    \\<title>Kite - Remote Control</title>
    \\<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-fonts@0.1.0/lib/addon-web-fonts.min.js"></script>
    \\<style>
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Regular.woff2") format("woff2");
    \\  font-weight: 400; font-style: normal;
    \\}
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Bold.woff2") format("woff2");
    \\  font-weight: 700; font-style: normal;
    \\}
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\:root {
    \\  --bg: #0a0a0a; --fg: #e0e0e0; --accent: #4fc3f7;
    \\  --card-bg: #1a1a1a; --border: #333;
    \\  --danger: #ef5350; --success: #66bb6a; --warn: #ffa726;
    \\}
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    \\  background: var(--bg); color: var(--fg);
    \\  height: 100dvh; display: flex; flex-direction: column; overflow: hidden;
    \\}
    \\
    \\/* Auth Screen */
    \\#auth-screen { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100dvh; padding: 2rem; }
    \\#auth-screen h1 { font-size: 1.5rem; margin-bottom: 1rem; color: var(--accent); }
    \\#auth-screen input { width: 100%; max-width: 400px; padding: 0.75rem; border: 1px solid var(--border); border-radius: 8px; background: var(--card-bg); color: var(--fg); font-size: 1rem; margin-bottom: 1rem; }
    \\#auth-screen button { padding: 0.75rem 2rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-size: 1rem; font-weight: 600; cursor: pointer; }
    \\#auth-error { color: var(--danger); margin-top: 0.5rem; display: none; }
    \\
    \\/* App Layout */
    \\#app { display: none; flex-direction: column; height: 100dvh; }
    \\header { display: flex; align-items: center; justify-content: space-between; padding: 0.5rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
    \\header h1 { font-size: 1rem; color: var(--accent); }
    \\.header-right { display: flex; align-items: center; gap: 0.5rem; }
    \\.status { font-size: 0.75rem; padding: 0.25rem 0.5rem; border-radius: 4px; }
    \\.status.running { background: var(--success); color: #000; }
    \\.status.waiting_input { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
    \\.status.stopped { background: var(--danger); color: #fff; }
    \\.status.starting { background: var(--accent); color: #000; }
    \\@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
    \\
    \\/* View Toggle */
    \\.view-toggle { display: flex; gap: 0; flex-shrink: 0; border-bottom: 1px solid var(--border); }
    \\.view-btn { flex: 1; padding: 0.5rem; text-align: center; cursor: pointer; border: none; background: transparent; color: var(--fg); font-size: 0.85rem; border-bottom: 2px solid transparent; }
    \\.view-btn.active { color: var(--accent); border-bottom-color: var(--accent); }
    \\.view-btn .badge { background: var(--warn); color: #000; border-radius: 10px; padding: 0 6px; font-size: 0.7rem; margin-left: 4px; }
    \\
    \\/* Status Card View */
    \\#status-view { flex: 1; padding: 1rem; overflow-y: auto; display: flex; flex-direction: column; gap: 1rem; }
    \\.session-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; padding: 1rem; }
    \\.session-card .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }
    \\.session-card .card-title { font-weight: 600; font-size: 0.9rem; }
    \\.session-card .card-activity { color: #888; font-size: 0.8rem; margin-bottom: 0.5rem; }
    \\
    \\/* Prompt Interaction */
    \\#prompt-section { display: none; }
    \\.prompt-summary { background: #111; border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; margin-bottom: 0.75rem; font-size: 0.85rem; color: #ccc; max-height: 200px; overflow-y: auto; white-space: pre-wrap; font-family: 'Hack Nerd Font Mono', monospace; }
    \\.prompt-options { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.75rem; }
    \\.prompt-options button { padding: 0.5rem 1rem; border: 1px solid var(--accent); border-radius: 8px; background: transparent; color: var(--accent); font-size: 0.85rem; cursor: pointer; transition: all 0.2s; }
    \\.prompt-options button:hover { background: var(--accent); color: #000; }
    \\.prompt-input-row { display: flex; gap: 0.5rem; }
    \\.prompt-input-row input { flex: 1; padding: 0.6rem 0.75rem; border: 1px solid var(--border); border-radius: 8px; background: var(--card-bg); color: var(--fg); font-size: 0.9rem; }
    \\.prompt-input-row button { padding: 0.6rem 1.2rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-weight: 600; cursor: pointer; }
    \\.expand-terminal-btn { display: block; width: 100%; padding: 0.5rem; margin-top: 0.5rem; border: 1px solid var(--border); border-radius: 8px; background: transparent; color: #888; font-size: 0.8rem; cursor: pointer; text-align: center; }
    \\
    \\/* Terminal View */
    \\#terminal-view { flex: 1; display: none; flex-direction: column; min-height: 0; }
    \\#terminal-container { flex: 1; min-height: 0; padding: 4px; }
    \\#terminal-container .xterm { height: 100%; }
    \\
    \\/* Events View */
    \\#events-view { flex: 1; overflow-y: auto; padding: 0.5rem; display: none; -webkit-overflow-scrolling: touch; }
    \\.event-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; margin-bottom: 0.5rem; }
    \\.event-card .event-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.25rem; }
    \\.event-card .event-type { font-size: 0.7rem; font-weight: 600; padding: 0.15rem 0.5rem; border-radius: 4px; }
    \\.event-type.PreToolUse { background: var(--warn); color: #000; }
    \\.event-type.PostToolUse { background: var(--success); color: #000; }
    \\.event-type.Notification { background: var(--accent); color: #000; }
    \\.event-type.SessionStart { background: #9c27b0; color: #fff; }
    \\.event-type.Stop { background: var(--danger); color: #fff; }
    \\.event-type.UserPromptSubmit { background: var(--accent); color: #000; }
    \\.event-card .event-time { font-size: 0.65rem; color: #888; }
    \\.event-card .event-detail { font-size: 0.75rem; color: #aaa; word-break: break-all; max-height: 4em; overflow: hidden; }
    \\.event-card .event-tool { font-weight: 600; color: var(--fg); font-size: 0.8rem; }
    \\</style>
    \\</head>
    \\<body>
    \\
    \\<div id="auth-screen">
    \\  <h1>Kite</h1>
    \\  <p style="margin-bottom:1rem;color:#888">Enter setup token to connect</p>
    \\  <input id="token-input" type="text" placeholder="Setup token..." autocomplete="off">
    \\  <button onclick="doAuth()">Connect</button>
    \\  <p id="auth-error">Invalid or expired token</p>
    \\</div>
    \\
    \\<div id="app">
    \\  <header>
    \\    <h1>Kite</h1>
    \\    <div class="header-right">
    \\      <span id="status" class="status starting">starting</span>
    \\    </div>
    \\  </header>
    \\
    \\  <div class="view-toggle">
    \\    <button class="view-btn active" onclick="switchView('status')" id="tab-status">Status</button>
    \\    <button class="view-btn" onclick="switchView('terminal')" id="tab-terminal">Terminal</button>
    \\    <button class="view-btn" onclick="switchView('events')" id="tab-events">Events <span id="event-badge" class="badge" style="display:none">0</span></button>
    \\  </div>
    \\
    \\  <div id="status-view">
    \\    <div class="session-card">
    \\      <div class="card-header">
    \\        <span class="card-title" id="session-title">Session</span>
    \\        <span id="session-status" class="status starting">starting</span>
    \\      </div>
    \\      <div class="card-activity" id="session-activity">Waiting for session...</div>
    \\    </div>
    \\
    \\    <div id="prompt-section">
    \\      <div class="prompt-summary" id="prompt-summary"></div>
    \\      <div class="prompt-options" id="prompt-options"></div>
    \\      <div class="prompt-input-row">
    \\        <input id="prompt-input" type="text" placeholder="Type your response..." autocomplete="off">
    \\        <button onclick="sendPromptResponse()">Send</button>
    \\      </div>
    \\      <button class="expand-terminal-btn" onclick="switchView('terminal')">Show full terminal</button>
    \\    </div>
    \\  </div>
    \\
    \\  <div id="terminal-view">
    \\    <div id="terminal-container"></div>
    \\  </div>
    \\
    \\  <div id="events-view"></div>
    \\</div>
    \\
    \\<script>
    \\let ws = null;
    \\let sessionToken = null;
    \\let eventCount = 0;
    \\let term = null;
    \\let fitAddon = null;
    \\let currentView = 'status';
    \\let currentSessionId = null;
    \\let lastActivity = '';
    \\
    \\const params = new URLSearchParams(location.search);
    \\const urlToken = params.get('token');
    \\if (urlToken) document.getElementById('token-input').value = urlToken;
    \\
    \\const saved = localStorage.getItem('kite_session');
    \\if (saved) { sessionToken = saved; initApp(); }
    \\
    \\function doAuth() {
    \\  const token = document.getElementById('token-input').value.trim();
    \\  if (!token) return;
    \\  fetch('/api/auth', {
    \\    method: 'POST',
    \\    headers: {'Content-Type':'application/json'},
    \\    body: JSON.stringify({setup_token: token})
    \\  }).then(function(r) { return r.json(); }).then(function(d) {
    \\    if (d.success) {
    \\      sessionToken = d.token;
    \\      localStorage.setItem('kite_session', d.token);
    \\      initApp();
    \\    } else {
    \\      document.getElementById('auth-error').style.display = 'block';
    \\    }
    \\  }).catch(function() {
    \\    document.getElementById('auth-error').style.display = 'block';
    \\  });
    \\}
    \\
    \\function initApp() {
    \\  document.getElementById('auth-screen').style.display = 'none';
    \\  document.getElementById('app').style.display = 'flex';
    \\  initTerminal();
    \\  connectWs();
    \\}
    \\
    \\function initTerminal() {
    \\  term = new window.Terminal({
    \\    cursorBlink: true, fontSize: 14,
    \\    fontFamily: "'Hack Nerd Font Mono', 'SF Mono', 'Menlo', monospace",
    \\    theme: { background: '#0a0a0a', foreground: '#e0e0e0', cursor: '#4fc3f7', selectionBackground: 'rgba(79,195,247,0.3)' },
    \\    allowProposedApi: true, scrollback: 10000, convertEol: false
    \\  });
    \\  fitAddon = new window.FitAddon.FitAddon();
    \\  term.loadAddon(fitAddon);
    \\  var webFontsAddon = new window.WebFontsAddon.WebFontsAddon();
    \\  term.loadAddon(webFontsAddon);
    \\  term.open(document.getElementById('terminal-container'));
    \\
    \\  term.onData(function(data) {
    \\    if (ws && ws.readyState === WebSocket.OPEN) {
    \\      ws.send(JSON.stringify({type:'terminal_input', data:data, session_id:currentSessionId}));
    \\    }
    \\  });
    \\  term.onResize(function(size) {
    \\    if (ws && ws.readyState === WebSocket.OPEN) {
    \\      ws.send(JSON.stringify({type:'resize', cols:size.cols, rows:size.rows, session_id:currentSessionId}));
    \\    }
    \\  });
    \\  window.addEventListener('resize', function() { if (currentView === 'terminal') fitAddon.fit(); });
    \\  new ResizeObserver(function() { if (currentView === 'terminal') fitAddon.fit(); }).observe(document.getElementById('terminal-container'));
    \\}
    \\
    \\function connectWs() {
    \\  var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    \\  ws = new WebSocket(proto + '//' + location.host + '/ws');
    \\  ws.binaryType = 'arraybuffer';
    \\  ws.onopen = function() { ws.send(JSON.stringify({type:'auth_token', token:sessionToken})); };
    \\  ws.onmessage = function(e) { try { handleMessage(JSON.parse(e.data)); } catch(err) { console.error('ws error:', err); } };
    \\  ws.onclose = function() { setTimeout(connectWs, 2000); };
    \\}
    \\
    \\function handleMessage(msg) {
    \\  switch (msg.type) {
    \\    case 'terminal_output':
    \\      if (term && msg.data) {
    \\        var bin = atob(msg.data);
    \\        var bytes = new Uint8Array(bin.length);
    \\        for (var j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
    \\        term.write(bytes);
    \\      }
    \\      break;
    \\    case 'hook_event':
    \\      addEvent(msg);
    \\      updateActivity(msg);
    \\      break;
    \\    case 'session_state_change':
    \\      updateSessionState(msg.state, msg.session_id);
    \\      break;
    \\    case 'prompt_request':
    \\      showPrompt(msg);
    \\      break;
    \\    case 'auth_result':
    \\      if (!msg.success) { localStorage.removeItem('kite_session'); location.reload(); }
    \\      break;
    \\  }
    \\}
    \\
    \\function switchView(view) {
    \\  currentView = view;
    \\  document.getElementById('status-view').style.display = view === 'status' ? 'flex' : 'none';
    \\  document.getElementById('terminal-view').style.display = view === 'terminal' ? 'flex' : 'none';
    \\  document.getElementById('events-view').style.display = view === 'events' ? 'block' : 'none';
    \\  document.querySelectorAll('.view-btn').forEach(function(b) { b.classList.remove('active'); });
    \\  document.getElementById('tab-' + view).classList.add('active');
    \\  if (view === 'terminal') {
    \\    setTimeout(function() { fitAddon.fit(); term.refresh(0, term.rows - 1); }, 50);
    \\  }
    \\}
    \\
    \\function updateSessionState(state, sessionId) {
    \\  currentSessionId = sessionId || currentSessionId;
    \\  var el = document.getElementById('status');
    \\  el.textContent = state;
    \\  el.className = 'status ' + state;
    \\  var sel = document.getElementById('session-status');
    \\  sel.textContent = state;
    \\  sel.className = 'status ' + state;
    \\
    \\  if (state === 'running') {
    \\    document.getElementById('prompt-section').style.display = 'none';
    \\    document.getElementById('session-activity').textContent = lastActivity || 'Running...';
    \\  } else if (state === 'stopped') {
    \\    document.getElementById('prompt-section').style.display = 'none';
    \\    document.getElementById('session-activity').textContent = 'Session ended.';
    \\  }
    \\}
    \\
    \\function showPrompt(msg) {
    \\  currentSessionId = msg.session_id || currentSessionId;
    \\  var section = document.getElementById('prompt-section');
    \\  section.style.display = 'block';
    \\
    \\  document.getElementById('prompt-summary').textContent = msg.summary || '';
    \\  document.getElementById('session-activity').textContent = 'Waiting for your input...';
    \\
    \\  var optionsEl = document.getElementById('prompt-options');
    \\  optionsEl.innerHTML = '';
    \\  if (msg.options && msg.options.length > 0) {
    \\    msg.options.forEach(function(opt) {
    \\      var btn = document.createElement('button');
    \\      btn.textContent = opt;
    \\      btn.onclick = function() { sendText(opt); };
    \\      optionsEl.appendChild(btn);
    \\    });
    \\  }
    \\
    \\  document.getElementById('prompt-input').value = '';
    \\  document.getElementById('prompt-input').focus();
    \\
    \\  if (currentView !== 'status') switchView('status');
    \\}
    \\
    \\function sendPromptResponse() {
    \\  var input = document.getElementById('prompt-input');
    \\  var text = input.value.trim();
    \\  if (!text) return;
    \\  sendText(text);
    \\}
    \\
    \\function sendText(text) {
    \\  if (ws && ws.readyState === WebSocket.OPEN) {
    \\    ws.send(JSON.stringify({type:'prompt_response', text:text, session_id:currentSessionId}));
    \\  }
    \\  document.getElementById('prompt-section').style.display = 'none';
    \\  document.getElementById('session-activity').textContent = 'Processing...';
    \\}
    \\
    \\function updateActivity(msg) {
    \\  if (msg.event === 'PreToolUse' && msg.tool) {
    \\    lastActivity = 'Using ' + msg.tool + '...';
    \\  } else if (msg.event === 'PostToolUse' && msg.tool) {
    \\    lastActivity = 'Finished ' + msg.tool;
    \\  } else if (msg.event === 'Notification') {
    \\    lastActivity = 'Notification received';
    \\  }
    \\  var el = document.getElementById('session-activity');
    \\  if (el) el.textContent = lastActivity;
    \\}
    \\
    \\function addEvent(msg) {
    \\  eventCount++;
    \\  var badge = document.getElementById('event-badge');
    \\  badge.style.display = 'inline';
    \\  badge.textContent = eventCount;
    \\  var panel = document.getElementById('events-view');
    \\  var card = document.createElement('div');
    \\  card.className = 'event-card';
    \\  var time = msg.ts ? new Date(msg.ts * 1000).toLocaleTimeString() : '';
    \\  card.innerHTML = '<div class="event-header"><span class="event-type ' + msg.event + '">' + msg.event + '</span><span class="event-time">' + time + '</span></div>' +
    \\    (msg.tool ? '<div class="event-tool">' + msg.tool + '</div>' : '') +
    \\    (msg.detail ? '<div class="event-detail">' + msg.detail.substring(0, 300) + '</div>' : '');
    \\  panel.prepend(card);
    \\}
    \\
    \\document.getElementById('prompt-input').addEventListener('keydown', function(e) {
    \\  if (e.key === 'Enter') { e.preventDefault(); sendPromptResponse(); }
    \\});
    \\</script>
    \\</body>
    \\</html>
;
```

- [ ] **Step 2: 运行构建确认编译通过**

Run: `zig build 2>&1 | head -20`
Expected: 编译通过

- [ ] **Step 3: 提交**

```bash
git add src/web.zig
git commit -m "feat(web): rewrite UI with status card and prompt interaction views"
```

---

## Task 10: root.zig 最终更新 + 集成验证

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: 确认 root.zig 导出完整**

最终的 `src/root.zig` 应为：

```zig
pub const Pty = @import("pty.zig").Pty;
pub const Session = @import("session.zig").Session;
pub const RingBuffer = @import("session.zig").RingBuffer;
pub const SessionState = @import("session.zig").SessionState;
pub const Auth = @import("auth.zig").Auth;
pub const Server = @import("http.zig").Server;
pub const WsBroadcaster = @import("ws.zig").WsBroadcaster;
pub const WsClient = @import("ws.zig").WsClient;
pub const SessionManager = @import("session_manager.zig").SessionManager;
pub const hooks = @import("hooks.zig");
pub const protocol = @import("protocol.zig");
pub const daemon = @import("daemon.zig");
pub const prompt_parser = @import("prompt_parser.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
```

- [ ] **Step 2: 运行全部测试**

Run: `zig build test 2>&1`
Expected: All tests pass

- [ ] **Step 3: 运行构建**

Run: `zig build 2>&1`
Expected: 编译成功，生成 `zig-out/bin/kite`

- [ ] **Step 4: 手动烟雾测试**

```bash
# 终端 1: 启动 daemon
zig-out/bin/kite start

# 终端 2: 创建 session
zig-out/bin/kite run --cmd /bin/bash

# 终端 3: 检查状态
zig-out/bin/kite status
```

Expected:
- `kite start` 打印 daemon 启动信息和认证 URL
- `kite run` 返回 session ID
- `kite status` 显示 daemon 正在运行

- [ ] **Step 5: 提交**

```bash
git add src/root.zig
git commit -m "feat: complete M1 integration - daemon mode with prompt interaction"
```

---

## 实施注意事项

1. **Task 依赖关系：** Task 1-3 可以并行。Task 4 依赖 Task 1-3。Task 5 独立。Task 6 独立。Task 7 依赖 Task 4 和 5。Task 8 依赖 Task 7。Task 9 独立（纯前端）。Task 10 依赖所有。

2. **编译问题：** 由于 Zig 的编译模型，中间步骤可能因为跨文件引用而编译失败。如果遇到，可以先在引用处用 `_ = @import(...)` 占位，最后统一修复。

3. **UserPromptSubmit 检测：** M1 使用 Stop hook 的 `stop_reason: "end_turn"` 来检测 Claude 等待输入。这是最可靠的方式。后续可以增加终端输出模式匹配作为补充。

4. **M1 限制：** 单 session（session ID 始终为 1），Web UI 仍嵌入二进制，无 JWT。这些在 M2-M4 中解决。
