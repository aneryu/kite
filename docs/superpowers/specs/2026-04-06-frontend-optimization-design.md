# Kite Frontend Optimization Design

## Overview

Kite 前端全面优化：视觉升级（赛博/终端风格）、多主题系统、智能折叠 SessionCard、轻量级过渡动画、响应式桌面适配。

**目标用户场景：** 手机为主，偶尔桌面。开发者群体，控制 AI 编程助手。

**技术方案：** CSS 变量 + `data-theme` 属性切换，不引入新依赖。

**设计参考：** Dark Mode (OLED) + Modern Dark (Cinema Mobile) 风格融合，字体配对 Orbitron（标题品牌） + 系统字体（UI）+ monospace（技术内容）。

---

## 1. 主题系统

### 机制

- `<html data-theme="cyber-dark">` 属性控制当前主题
- 主题选择存 `localStorage('kite-theme')`
- 支持 `auto` 值，通过 `prefers-color-scheme` 媒体查询跟随系统，自动映射到 Cyber Dark / Cyber Light

### 预设主题

| 主题 | 底色 | 卡片背景 | Accent | 风格 |
|------|------|---------|--------|------|
| Cyber Dark（默认） | `#0a0a0a` | `rgba(255,255,255,0.05)` + blur | `#4fc3f7` 青蓝 | 微光边框、glow |
| Cyber Light | `#f0f2f5` | `rgba(255,255,255,0.7)` + blur | `#0288d1` 深蓝 | 亮色科技感 |
| Monokai | `#272822` | `#3e3d32` | `#f92672` 玫红 | 经典终端暖色 |
| Nord | `#2e3440` | `#3b4252` | `#88c0d0` 霜蓝 | 冷色柔和 |

### CSS 变量

在现有变量基础上新增：

| 变量 | 用途 |
|------|------|
| `--card-bg-alpha` | 毛玻璃背景色（半透明） |
| `--glow-color` | 状态发光色（基于 accent） |
| `--border-glow` | 微光边框色 |
| `--text-secondary` | 二级文字（替代硬编码 `#888`, `#999`） |
| `--text-muted` | 弱文字（替代硬编码 `#666`） |

现有变量保留：`--bg`, `--fg`, `--accent`, `--card-bg`, `--border`, `--danger`, `--success`, `--warn`。

### 切换入口

Header 右侧添加主题切换按钮，点击展开下拉菜单。菜单项：Auto / Cyber Dark / Cyber Light / Monokai / Nord。

---

## 2. 视觉升级

### 卡片

- 背景：`var(--card-bg-alpha)` + `backdrop-filter: blur(12px)`
- 边框：`1px solid var(--border-glow)`（`rgba(accent, 0.2)`）
- hover 时边框增亮至 `rgba(accent, 0.4)`
- **毛玻璃降级：** 通过 `@supports not (backdrop-filter: blur(1px))` 回退到 `var(--card-bg)` 纯色半透明背景，确保低端设备可用

### 状态指示

| 状态 | 视觉表现 |
|------|---------|
| running | accent 色圆点 + 微弱 `box-shadow` glow |
| waiting / asking | 橙色脉冲动画 + glow |
| stopped | 暗灰色，无发光 |
| waiting_permission | 琥珀色 glow |

### 按钮

- 主按钮（Connect、Send）：accent 填充 + 轻微 glow `box-shadow`
- 次按钮（Terminal、快捷键）：透明背景 + accent 边框
- FAB：加 `box-shadow` glow

### 字体

- 品牌标题（header "Kite"）：Orbitron（Google Fonts），增强科技感
- UI 文字：系统字体（保持现有 `-apple-system` 栈）
- 技术内容（session ID、工具名、状态码）：monospace
- 终端：保持 Hack Nerd Font Mono 配置
- 加载策略：Orbitron 通过 `<link rel="preload">` + `font-display: swap` 加载，避免 FOIT

### 硬编码颜色清理

将所有组件中散落的硬编码色值统一替换为 CSS 变量：

- `#888`, `#999` → `var(--text-secondary)`
- `#666` → `var(--text-muted)`
- `#ccc` → `var(--fg)` 或新变量
- `#ff7b72` → `var(--danger)`
- `#9aa0a6` → `var(--text-secondary)`

---

## 3. 信息架构 — 智能折叠 SessionCard

### 默认状态（折叠）

- 第一行：`#id` + session 名称 + 状态徽章 + Terminal 按钮
- 第二行：当前 activity 或 last_message，单行截断

### 自动展开

- 条件：session 状态为 `waiting` 或 `asking`
- 展开区域：prompt 摘要 + 选项按钮 + 文本输入

### 任务与子 agent 折叠

- 默认隐藏，显示一行摘要：`Tasks: 3/5 done` 或 `Subagents: 2 running`
- 点击摘要行展开完整列表
- 展开后保留现有截断逻辑（最多 5 任务 / 4 agent）

---

## 4. 交互与过渡

### 页面切换

- 列表 → 详情：详情从右侧滑入，`transform: translateX(100%) → 0`，200ms ease-out
- 详情 → 列表：反向滑出
- 使用 Svelte `transition` 指令实现

### 卡片交互

- 折叠/展开：高度过渡 150ms + 内容淡入淡出
- prompt 区域出现时轻微向上滑入

### 按钮反馈

- `:active` 状态加 `transform: scale(0.96)` + `transition: transform 0.1s`，保留现有背景色变化
- prompt 选项选中时 accent 填充过渡

### 无障碍动画

- 全局添加 `@media (prefers-reduced-motion: reduce)` 规则：
  - 禁用 pulse 脉冲动画（状态徽章改为静态高亮）
  - 页面滑动改为即时切换（`transition-duration: 0s`）
  - glow box-shadow 保留（非运动效果），但移除所有 `animation` 属性
- 折叠/展开高度过渡保留但缩短至 0ms

### 主题切换

- CSS 变量加 `transition: background-color 0.2s, color 0.2s, border-color 0.2s`
- 整体颜色平滑过渡

---

## 5. 触摸与可访问性

### 触摸目标

- 所有可交互元素最小尺寸 **44x44px**（含 hit area）
- SessionDetail 快捷键按钮行：当前 `gap: 0` 改为 `gap: 1px`（视觉分隔线），每个按钮 `min-height: 44px`
- Terminal 按钮、FAB、prompt 选项按钮均确保 44px 最小触摸区域
- 主题下拉菜单项 `min-height: 44px`

### 触摸间距

- 快捷键按钮之间保持 `border-right: 1px solid var(--border)` 作为视觉分隔（当前已有）
- prompt 选项按钮之间 `gap: 0.4rem`（约 6.4px），接近但可接受（按钮本身 padding 提供额外空间）

### 全局触摸优化

- `body` 添加 `touch-action: manipulation`，消除 300ms tap delay
- 可点击元素添加 `cursor: pointer`

### 焦点状态

- 所有可交互元素添加 `:focus-visible` 样式：`outline: 2px solid var(--accent); outline-offset: 2px`
- 非键盘交互（触摸、鼠标）不显示焦点环

### z-index 层级

| 层级 | z-index | 用途 |
|------|---------|------|
| 内容 | 0 | 正常文档流 |
| FAB | 10 | 浮动操作按钮 |
| PromptOverlay | 20 | 底部 prompt 栏（已有） |
| 主题下拉菜单 | 30 | header 下拉菜单 |

---

## 6. 响应式与桌面适配

### 手机端（< 640px）

- 全宽布局，保持当前行为

### 桌面端（≥ 640px）

- 内容区域 `max-width: 640px`，水平居中
- SessionDetail 终端区域 `max-width: 960px`
- FAB 跟随内容区域定位
- 快捷键按钮行间距适当加大

### 安全区域

- 保持 `env(safe-area-inset-bottom)` 处理
- header 加 `padding-top: env(safe-area-inset-top)` 适配刘海屏

---

## 涉及文件

| 文件 | 改动 |
|------|------|
| `web/src/app.css` | 主题变量定义、全局过渡、响应式断点 |
| `web/src/App.svelte` | 主题切换组件、页面过渡动画、header 改造 |
| `web/src/components/SessionCard.svelte` | 智能折叠、视觉升级、硬编码颜色替换 |
| `web/src/components/SessionList.svelte` | FAB glow、响应式布局 |
| `web/src/components/SessionDetail.svelte` | 页面滑入动画、按钮样式、响应式 |
| `web/src/components/TerminalView.svelte` | 终端主题色跟随：主题切换时读取 CSS 变量更新 `terminal.options.theme`（background、foreground、cursor） |
| `web/src/components/PromptOverlay.svelte` | 视觉升级、硬编码颜色替换 |
| `web/src/lib/theme.ts`（新建） | 主题管理：读写 localStorage、系统偏好监听、切换逻辑 |

---

## 附录：空状态优化

SessionList 空状态改进：
- 居中布局，加一个简约的终端图标（SVG）
- 主文案："No active sessions"
- 副文案："Run `kite run` to start a session, or tap + below"
- 图标 + 文案使用 `var(--text-muted)` 色
