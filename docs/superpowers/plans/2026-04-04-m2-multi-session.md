# M2: 多 Session 管理 + 状态概览 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 支持同时管理多个 CLI session，提供 session 列表和状态概览。

**Architecture:** M1 已搭好多 session 基础设施（SessionManager 用 HashMap 管理多个 ManagedSession）。M2 补全 REST API（GET/:id、DELETE/:id）、添加 session 上限、重写 Web UI 为列表+详情视图。

**Tech Stack:** Zig 0.15.2, xterm.js 5.5.0, WebSocket

---

## 文件结构

### 修改文件
| 文件 | 变更 |
|------|------|
| `src/session_manager.zig` | 添加 session 上限常量和检查 |
| `src/http.zig` | 实现 GET/DELETE /api/sessions/:id，路径参数解析 |
| `src/protocol.zig` | 添加 session list 编码函数 |
| `src/web.zig` | 重写 UI：session 列表视图 + 详情视图 + session 切换 |
| `src/main.zig` | kite run 支持 --attach 已有 session |

---

## Task 1: SessionManager 添加 session 上限

**Files:** `src/session_manager.zig`

- [ ] 在 SessionManager struct 中添加常量和检查：

```zig
pub const max_sessions: usize = 8;
```

在 `createSession` 开头（mutex lock 之后）添加上限检查：

```zig
if (self.sessions.count() >= max_sessions) {
    return error.SessionLimitReached;
}
```

需要在 error set 中加入：在 Pty.SpawnError 基础上添加 `SessionLimitReached`。

- [ ] 运行 `zig build test`
- [ ] 提交：`feat(session-manager): add session limit (max 8)`

---

## Task 2: HTTP API 完善 — GET/:id 和 DELETE/:id

**Files:** `src/http.zig`

- [ ] 添加路径参数解析辅助函数：

```zig
fn parseSessionIdFromPath(path: []const u8) ?u64 {
    // 匹配 /api/sessions/<id>
    const prefix = "/api/sessions/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id_str = path[prefix.len..];
    return std.fmt.parseInt(u64, id_str, 10) catch null;
}
```

- [ ] 更新 `handleSessionsApi` 路由：

对 `/api/sessions/<id>` 路径：
- GET → 返回单个 session JSON
- DELETE → 调用 `session_manager.destroySession(id)`，返回 `{"ok":true}`

- [ ] `handleCreateSession` 中处理 `SessionLimitReached` 错误，返回 429 status

- [ ] 运行 `zig build test`
- [ ] 提交：`feat(http): implement GET/DELETE /api/sessions/:id`

---

## Task 3: Protocol 补充

**Files:** `src/protocol.zig`

- [ ] 添加 `encodeSessionList` 函数：

```zig
pub fn encodeSessionList(allocator: std.mem.Allocator, sessions: []const @import("session_manager.zig").SessionInfo) ![]u8
```

生成 JSON 数组格式：
```json
{"type":"session_list","sessions":[{"id":1,"state":"running","command":"claude","cwd":"/path"},...]}
```

- [ ] 添加 `encodeSessionCreated` 和 `encodeSessionDestroyed` 广播消息

- [ ] 运行 `zig build test`
- [ ] 提交：`feat(protocol): add session list and lifecycle messages`

---

## Task 4: kite run 支持 attach 到已有 session

**Files:** `src/main.zig`

- [ ] `kite run` 添加 `--attach <id>` 参数，直接 attach 到已有 session（跳过 HTTP 创建）

- [ ] 无参数时行为不变（创建新 session + attach）

- [ ] 更新 printUsage

- [ ] 运行 `zig build`
- [ ] 提交：`feat(main): kite run --attach to existing session`

---

## Task 5: Web UI 重写 — 多 Session 列表 + 详情

**Files:** `src/web.zig`

这是 M2 最大的改动。Web UI 需要：

### Session 列表视图（首页）
- 卡片列表，每个 session 显示：ID、命令、cwd、状态
- 状态颜色：running(绿)、waiting_input(橙色闪烁)、stopped(灰)
- waiting_input 排最前
- 底部"+"按钮创建新 session
- 点击卡片进入详情

### Session 详情视图
- 顶部返回按钮 + session 标题 + 状态
- 复用 M1 的三个 tab（Status/Terminal/Events）
- 所有 WebSocket 消息按 session_id 过滤

### 关键变更
- 页面初始化时 fetch GET /api/sessions 获取列表
- WebSocket 消息按 session_id 路由到对应 session 的数据
- 创建新 session 时弹出简单对话框输入命令
- 删除 session（长按或滑动删除）

- [ ] 重写 web.zig
- [ ] 运行 `zig build`
- [ ] 提交：`feat(web): multi-session list view with detail navigation`

---

## Task 6: 集成验证

- [ ] `zig build test` — all pass
- [ ] `zig build` — 编译成功
- [ ] 手动测试：
  - kite start
  - kite run --cmd /bin/bash (创建 session 1)
  - kite run --cmd /bin/bash (创建 session 2)
  - Web UI 显示两个 session 卡片
  - 点击 session 卡片进入详情
  - DELETE session
- [ ] 提交：`feat: complete M2 - multi-session management`
