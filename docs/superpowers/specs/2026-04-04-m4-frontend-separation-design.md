# M4：前后端分离

## 概述

将 Kite 从嵌入式 Web 应用改造为前后端分离架构。后端变为纯 API 服务，前端独立为 Svelte 项目（`web/` 目录）。同时暂时关闭 auth 校验，后续再完善。

本里程碑替代原路线图中的 M4（API 规范化 + 客户端分离），其中 API v1 版本化已在之前完成。

## 核心设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 前端框架 | Svelte 5 + TypeScript + Vite | 编译时框架，bundle 小，复杂度匹配 |
| 项目位置 | monorepo `web/` 目录 | 方便一起改，统一管理 |
| Auth 处理 | 保留代码，`--no-auth` 跳过校验 | 不删代码，后续可直接重新启用 |
| 静态文件服务 | `--static-dir` 可选参数 | 灵活：可独立部署，也可 daemon 托管 |
| 迁移策略 | 参考现有逻辑重写为 Svelte，然后删除 web.zig | 干净切换，不保留 fallback |
| 执行顺序 | 先后端改造，再前端开发 | API 先稳定，前端在稳定接口上开发 |

---

## 1. 后端改造

### 1.1 Auth 跳过机制

- `Auth` 增加 `disabled: bool` 字段
- `kite start --no-auth` 设置 `disabled = true`
- `validateSessionToken()` 在 disabled 时直接返回 `true`
- WebSocket 连接在 auth disabled 时自动标记 `client.authenticated = true`
- HTTP API 路由中的 token 校验同理跳过
- 保留所有现有 auth 代码

### 1.2 静态文件服务

- `kite start --static-dir ./web/dist` 指定前端构建产物目录
- 非 `/api/` 和非 `/ws` 的请求 fallback 到静态文件服务
- SPA fallback：找不到文件时返回 `index.html`
- 不指定 `--static-dir` 时，非 API 路径返回 404

### 1.3 CORS 支持

- `--no-auth` 模式下自动启用 CORS：
  - `Access-Control-Allow-Origin: *`
  - `Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS`
  - `Access-Control-Allow-Headers: Content-Type, Authorization`
- 处理 OPTIONS preflight 请求，返回 204
- 生产环境可配置限定 origin

### 1.4 删除 web.zig

- 删除 `web.zig` 文件
- 移除 `http.zig` 中对 `web.zig` 的 import 和嵌入式 HTML 服务逻辑
- `serveStaticFile` 改为从 `--static-dir` 读取文件

### 1.5 Hook 端点

新增 `POST /api/v1/hooks` 端点，接收 Claude Code HTTP 类型的 hook 事件。根据 `hook_event_name` 字段分发处理，更新 session 状态，通过 WebSocket 广播给前端。

保留现有的 Unix Socket IPC 方式（`hooks.zig`、`kite hook` 命令、IPC listener），用于兼容其他工具。两种 hook 接入方式并存：
- **HTTP hook**：Claude Code 原生 HTTP hook 类型，直接 POST 到 daemon
- **IPC hook**：现有的 `kite hook --event <E>` 命令通过 Unix Socket 转发，兼容其他 CLI 工具

### 1.6 Session 数据模型扩展

```
Session {
  // 现有字段...
  tasks: []Task,              // {id, subject, description, status}
  subagents: []Subagent,      // {id, type, status, started_at}
  current_activity: ?Activity, // {tool_name, summary}
  last_prompt: ?str,          // 最近的 UserPromptSubmit 内容
}
```

---

## 2. 前端项目（`web/`）

### 2.1 项目结构

```
web/
├── package.json
├── vite.config.ts          # proxy /api /ws 到 localhost:7890
├── tsconfig.json
├── index.html
└── src/
    ├── main.ts             # 入口
    ├── App.svelte          # 根组件，路由切换
    ├── lib/
    │   ├── api.ts          # HTTP API 封装（fetch wrapper）
    │   └── ws.ts           # WebSocket 连接管理、自动重连、消息分发
    ├── stores/
    │   └── sessions.ts     # session 列表 + 当前 session 状态
    └── components/
        ├── SessionList.svelte      # session 列表视图
        ├── SessionCard.svelte      # 单个 session 富卡片
        ├── SessionDetail.svelte    # session 详情（全屏终端）
        ├── PromptOverlay.svelte    # prompt 交互浮层
        └── TerminalView.svelte     # xterm.js 终端视图
```

### 2.2 技术选型

- Svelte 5 + TypeScript
- Vite 6，dev server proxy WebSocket 和 API 到后端
- xterm.js + @xterm/addon-fit
- 不引入路由库，用简单的组件状态切换（列表/详情两层）
- 不引入 CSS 框架，沿用现有暗色主题设计语言（CSS 变量）

### 2.3 核心数据流

```
WebSocket 消息 → ws.ts 解析 → sessions store 更新 → 组件响应式渲染
用户操作 → 组件事件 → ws.ts 发送 / api.ts 调用 → 后端处理
```

### 2.4 开发体验

- `cd web && npm run dev` — Vite dev server（端口 5173），proxy 到 `localhost:7890`
- `npm run build` — 产物输出到 `web/dist/`
- 生产部署：`kite start --static-dir ./web/dist`

---

## 3. 交互设计

### 3.1 交互模型

```
Session 列表（富卡片）  →  点击  →  Web 终端（全屏 xterm.js）
                         ←  返回  ←
```

两层结构。Prompt 交互通过终端页面底部浮层处理。

### 3.2 Session 卡片信息结构

```
┌─────────────────────────────────────────┐
│  kite · plan                 Claude  ⌨  │  ← 名称 + 工具标签
│  👤 你：1                               │  ← 最新交互
│  Bash zig build test 2>&1               │  ← 当前活动
├─────────────────────────────────────────┤
│  任务 (3 已完成, 7 待完成)               │
│  ☐ Task4: SessionManager                │
│  ☐ Task6: Hook 系统更新                 │
│  ✅ Task1: Session 状态机扩展            │
│  ... +1 已完成                           │
├─────────────────────────────────────────┤
│  ⑂ Subagents (6)                        │
│  🟢 Task 1: Session state  完成         │
│  🔵 Task 4: SessionManager  18s         │
│  ...                                    │
└─────────────────────────────────────────┘
```

### 3.3 数据来源映射

| 卡片区域 | Hook 事件 | 数据字段 |
|---------|----------|---------|
| 当前活动 | `PreToolUse` | tool_name + tool_input 摘要 |
| 活动结束 | `PostToolUse` / `PostToolUseFailure` | 清除或更新活动状态 |
| 任务新增 | `TaskCreated` | task_id, task_subject, task_description → pending |
| 任务完成 | `TaskCompleted` | task_id → completed |
| Subagent 启动 | `SubagentStart` | agent_id, agent_type → running |
| Subagent 结束 | `SubagentStop` | agent_id → 完成，记录耗时 |
| Prompt 等待 | `UserPromptSubmit` | prompt 内容，session 进入 waiting_input |
| 通知 | `Notification` | message, title |

### 3.4 Hook 配置

`kite setup` 自动写入项目的 `.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "PostToolUseFailure": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "TaskCreated": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "TaskCompleted": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "SubagentStart": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "SubagentStop": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }],
    "Notification": [{ "matcher": "*", "hooks": [{ "type": "http", "url": "http://localhost:7890/api/v1/hooks" }] }]
  }
}
```

### 3.5 Task 状态

Hooks 只提供 `TaskCreated`（pending）和 `TaskCompleted`。不区分 pending/in_progress，前端展示两种状态：待完成和已完成。

### 3.6 Prompt 交互

waiting_input 时：
- 卡片上橙色高亮 + prompt 摘要
- 点击进入终端，底部浮层显示选项按钮 + 输入框
- 也可直接在终端中操作

---

## 4. 功能迁移范围

### P0 — 核心功能

- Session 列表：富卡片展示（任务、subagent、当前活动）、waiting_input 优先排序
- Session 详情：全屏 xterm.js 终端
- Prompt 交互：底部浮层（摘要 + 选项按钮 + 输入框）
- 终端视图：xterm.js 渲染、键盘输入、resize 同步

### P1 — 重要体验

- WebSocket 自动重连 + 终端历史恢复
- 创建/删除 session
- 快捷操作栏（Ctrl+C、Tab、方向键、Esc）
- 手机端适配（虚拟键盘、safe area）

### P2 — 不在本 M4 范围

- Auth 页面（等 auth 机制重新设计后做）
- 用量信息展示（等 Claude Code 支持 usage hook）
- 系统推送通知
- 原生移动端（Android/iOS）
