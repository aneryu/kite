# Kite 产品功能路线图

## 概述

Kite 是一个 AI 编码助手的远程控制器，通过 PTY 代理 CLI 工具，暴露 WebSocket + HTTP 服务，支持从手机浏览器或原生 App 进行远程控制。

当前 MVP 已实现：单进程 PTY 代理、HTTP/WebSocket 服务器、Token 认证、Claude Code Hook 集成、嵌入式移动端 Web UI。

本路线图规划从 MVP 到 1.0 的功能迭代，采用里程碑制，每个里程碑是一个可用的交付物。

## 核心设计决策

| 决策 | 选择 | 理由 |
|------|------|------|
| 进程模型 | 后台 daemon，tmux 式 session 管理 | 支持多 CLI 实例，解耦生命周期 |
| 客户端架构 | 服务端纯 API，Web/Android/iOS 独立开发 | 各端最佳体验，独立迭代 |
| 核心交互 | UserPromptSubmit 驱动 | 这是用户最频繁需要介入的场景 |
| 交互模式 | 摘要 + 选项按钮 + 输入框，可展开终端 | 平衡效率与上下文 |
| 通知方式 | App 内通知（WebSocket 推送） | M1-M5 阶段足够，后续可加系统推送 |

---

## M1：Daemon 化 + UserPromptSubmit 核心交互

**目标：** 将 Kite 改造为后台 daemon，实现最核心的"手机收到通知 → 快速回复"链路。

### 服务端

#### Daemon 进程模型
- `kite start` 变为后台 daemon 进程（fork 后 detach，或由 launchd/systemd 管理）
- 监听两个通道：HTTP/WebSocket（客户端通信）+ Unix Socket（Hook IPC）
- 引入 SessionManager，管理 PTY session 的生命周期（M1 阶段支持单个 session，多 session 在 M2）

#### Session 生命周期
- `kite run [--cmd claude] [--cwd /path/to/project]` → 通过 API 请求 daemon 创建新 PTY session
- daemon fork 子进程，分配 session ID，开始 I/O relay
- session 状态机：`starting → running → waiting_input → stopped`
- `waiting_input` 为新增状态，当检测到 UserPromptSubmit hook 时进入

#### Hook 重设计
- Hook 事件通过 Unix Socket 到达 daemon，根据 session 匹配关联
- 重点处理 `UserPromptSubmit`：解析 Claude Code 的输出，提取上下文摘要和选项
- 其他 Hook（PreToolUse、PostToolUse、Notification 等）作为状态信息存储和广播，不阻塞

### 客户端（Web，仍嵌入二进制，M4 再分离）

#### 默认视图——Session 状态卡片
- 显示当前 session 的状态（running / waiting input）
- running 时：显示简要的活动信息（如"正在执行 Edit tool..."）
- waiting_input 时：高亮提示，展示摘要 + 输入区域

#### UserPromptSubmit 交互
- **摘要区：** 显示 Claude 最近输出的关键内容（最后的问题/提示）
- **选项按钮：** 如果检测到选项（yes/no、approve/reject 等），渲染为可点击按钮
- **自由输入框：** 用户可以直接打字输入任意内容
- **一键展开：** 可展开完整终端查看上下文

#### 终端模式
- 任何时候用户都可以切换到完整终端视图
- 终端模式下为现有的 xterm.js 交互

---

## M2：多 Session 管理 + 状态概览

**目标：** 支持同时管理多个 CLI session，提供状态概览列表。

### 服务端

#### SessionManager 扩展
- 支持同时管理多个 PTY session，每个 session 独立的 PTY fd、ring buffer、状态机
- Session CRUD API：
  - `POST /api/sessions` — 创建新 session（参数：cmd、cwd）
  - `GET /api/sessions` — 列出所有 session 及其状态
  - `GET /api/sessions/:id` — 获取单个 session 详情
  - `DELETE /api/sessions/:id` — 终止并销毁 session
- 每个 session 有独立的 WebSocket channel（通过 session ID 区分消息）

#### 资源管理
- 每个 session 一个 PTY fd + 一个 I/O relay 线程
- session 上限可配置（默认 8 个），防止资源耗尽
- 子进程退出时自动清理 session，状态变为 `stopped`

### 客户端

#### Session 列表视图（首页）
- 卡片列表，每个 session 显示：session ID、命令、工作目录、当前状态
- 状态标记：`running`（绿色）、`waiting_input`（橙色闪烁）、`stopped`（灰色）
- `waiting_input` 的 session 自动排到最前面（需要关注的优先）
- 底部"+"按钮创建新 session

#### Session 详情视图
- 点击卡片进入，复用 M1 的交互（状态卡片 / UserPromptSubmit 交互 / 终端模式）
- 左滑/右滑或顶部 tab 切换不同 session

---

## M3：完整终端交互增强

**目标：** 提供生产级的终端交互体验。

### 服务端

#### 终端输出缓冲增强
- ring buffer 从 64KB 扩大为可配置（默认 256KB），支持更长的历史
- 新增 terminal snapshot API：`GET /api/sessions/:id/terminal` — 返回当前终端屏幕内容（用于客户端重连恢复）

#### 终端输入增强
- 支持 resize 同步：客户端发送窗口大小变化，daemon 通过 `TIOCSWINSZ` 同步到 PTY
- 输入通道增加简单的流控，防止客户端快速粘贴大段文本时丢数据

### 客户端

#### 终端体验优化
- xterm.js 完整配置：scrollback、搜索、选择复制
- 使用 xterm.js 的 refresh API 做局部和全屏刷新，避免每次重写整个 buffer
- 手机端适配：虚拟键盘弹出时自动调整终端区域大小
- 快捷操作栏：常用按键（Ctrl+C、Tab、↑↓方向键、Esc）作为底部工具栏按钮，方便手机触控
- 长按粘贴支持

#### 重连恢复
- WebSocket 断开后自动重连，重连时从 terminal snapshot API 恢复屏幕状态
- 利用 xterm.js refresh 做恢复后的屏幕刷新
- 不丢失断线期间的输出（从 ring buffer 补发）

---

## M4：API 规范化 + 客户端分离

**目标：** 将 Kite 从嵌入式 Web 应用改造为纯 API 服务，为多端客户端做准备。

### 服务端

#### API 规范化
- 定义完整的 REST API 规范，覆盖：
  - 认证：`POST /api/v1/auth/setup`、`POST /api/v1/auth/token`
  - Session CRUD：`POST/GET/DELETE /api/v1/sessions[/:id]`
  - Terminal I/O：WebSocket 协议定义（消息类型、格式、流控）
  - Hook 事件：`GET /api/v1/sessions/:id/events`（查询历史事件）
  - 状态推送：WebSocket 上的 session 状态变更通知协议
- 所有 API 使用统一的 JSON 格式，错误码标准化
- URL 前缀 `/api/v1/` 版本化

#### 客户端分离
- 移除 `web.zig` 中嵌入的 HTML/JS（不再 comptime 嵌入）
- Web 客户端独立为单独的项目/仓库
- Kite daemon 变为纯 API 服务，可选提供静态文件服务指向外部 Web 构建产物
- WebSocket 协议文档化，定义清晰的消息类型枚举，供各端客户端实现

#### 认证增强
- Setup token 流程保留，session token 改为 JWT，包含过期时间
- 支持 token refresh

### Web 客户端（独立项目）
- 独立前端工程，框架选型后续决定
- 复用 M1-M3 已验证的交互设计
- 通过标准 API 与 daemon 通信，不依赖嵌入式特性

---

## M5：移动端客户端（Android / iOS）

**目标：** 交付原生移动端客户端，复用 M4 的 API 协议。

### 设计原则
- Android 和 iOS 各自原生开发
- 交互模式与 Web 端一致，针对移动端特性做适配

### Android 客户端
- **语言：** Kotlin
- **终端渲染：** 可选方案——WebView 嵌入 xterm.js，或原生终端渲染库（如 Termux terminal-emulator）
- **后台连接：** 前台 Service 维持 WebSocket 连接，接收 `waiting_input` 状态变更
- **App 内通知：** 收到 `waiting_input` 时弹出顶部横幅通知
- **手势：** 滑动切换 session、长按粘贴、双指缩放终端字体

### iOS 客户端
- **语言：** Swift/SwiftUI
- **终端渲染：** 可选方案——WebView + xterm.js，或原生方案（如 SwiftTerm）
- **后台连接：** URLSessionWebSocketTask，前台时保持长连接
- **App 内通知：** 同 Android，顶部横幅提示
- **iOS 适配：** Safe Area、键盘弹出动画、Haptic 反馈

### 两端共同点
- Session 列表视图 → Session 详情（状态卡片 / 输入交互 / 终端）
- UserPromptSubmit 交互：摘要 + 选项按钮 + 输入框 + 展开终端
- 快捷操作栏：Ctrl+C、Tab、方向键等常用按键
- 断线重连 + 终端状态恢复
