# WebRTC P2P 远程控制

## 概述

将 Kite 的远程控制通道从"浏览器直连 daemon WebSocket"改为"基于 WebRTC DataChannel 的 P2P 连接"。解决开发机在内网、手机在外网时无法直连的 NAT 穿透问题。

WebRTC 成为唯一的远程通信通道，现有的 HTTP server 和 WebSocket server 从 daemon 中移除。

## 架构

```
┌─────────────┐         WebSocket          ┌──────────────────┐
│  手机浏览器  │◄─────────────────────────►│  信令服务器 (Go)  │
│             │    SDP/ICE 交换 + 认证      │   公网 VPS        │
└──────┬──────┘                            └────────┬─────────┘
       │                                            │
       │  DataChannel (P2P 或 TURN relay)   WebSocket│
       │                                            │
       │         ┌──────────────────────────────────┘
       │         │
┌──────▼─────────▼──┐
│   Kite daemon      │
│   (开发机, 内网)    │
│                    │
│  ┌──────────────┐  │
│  │libdatachannel│  │   Unix socket
│  │  C bindings  │◄─┼──────────────── Claude Code hooks
│  └──────────────┘  │
│  ┌──────────────┐  │
│  │ PTY + Session │  │
│  │   Manager     │  │
│  └──────────────┘  │
└────────────────────┘
```

三个组件：

1. **信令服务器**（Go，公网 VPS）：纯中继，转发 SDP/ICE candidates 和认证消息。无状态，不存储任何终端数据。daemon 和浏览器都通过 WebSocket 连接它。同时托管前端静态文件。
2. **Kite daemon**（Zig，开发机）：不再开放任何端口。启动时主动连接信令服务器注册自己。通过 libdatachannel 作为 WebRTC peer，用 DataChannel 传输所有数据。
3. **手机浏览器**（Svelte）：连接信令服务器完成认证和 WebRTC 握手，之后所有通信走 DataChannel。

## 连接生命周期

### 配对与连接建立

```
1. daemon 启动
   ├─ 生成 pairing_code（6位随机字母数字）
   ├─ 生成 setup_token（32字节随机，5分钟有效）
   ├─ 连接信令服务器（WebSocket），用 pairing_code 注册房间
   └─ 终端显示 QR 码：https://signal.example.com/#/pair/{pairing_code}
      同时显示 pairing_code 文本（手动输入备选）

2. 手机扫码 / 输入 pairing_code
   ├─ 打开页面，连接信令服务器，加入房间
   ├─ 信令服务器通知 daemon：浏览器已加入
   ├─ daemon 通过信令发送 setup_token 给浏览器
   ├─ 浏览器回发 { type: "auth", token: "..." }
   ├─ daemon 验证，生成 session_token（64字节，24h有效）
   ├─ 返回 { type: "auth_result", success: true, session_token: "..." }
   └─ 浏览器保存 session_token 到 localStorage

3. WebRTC 握手（认证通过后）
   ├─ 浏览器创建 RTCPeerConnection + DataChannel
   ├─ 浏览器生成 SDP offer → 信令服务器 → daemon
   ├─ daemon 通过 libdatachannel 生成 SDP answer → 信令服务器 → 浏览器
   ├─ 双方交换 ICE candidates（trickle ICE）
   └─ DataChannel 打开

4. 正常通信（全部走 DataChannel）
   ├─ daemon → 浏览器：terminal_output, session_state_change, prompt_request 等
   ├─ 浏览器 → daemon：terminal_input, resize, prompt_response 等
   └─ 信令 WebSocket 保持连接（用于重连触发）
```

### 重连认证

浏览器已有 session_token 时，跳过扫码配对。浏览器同时在 localStorage 保存 pairing_code，重连时用它加入同一房间，然后发送 `{ type: "auth", session_token: "..." }` 认证后开始 WebRTC 握手。

如果 daemon 已重启（pairing_code 变了），房间不存在，信令服务器返回错误，浏览器清除本地状态，回到"请扫码或输入配对码"界面。

## 协议与消息格式

### DataChannel 消息（复用现有协议）

| 方向 | 类型 | 说明 |
|------|------|------|
| daemon → 浏览器 | `terminal_output` | Base64 编码终端数据 |
| daemon → 浏览器 | `session_state_change` | 会话状态变更 |
| daemon → 浏览器 | `sessions_sync` | 连接建立后全量同步 |
| daemon → 浏览器 | `prompt_request` | 等待用户输入 |
| daemon → 浏览器 | `task_update` / `subagent_update` / `activity_update` | 进度通知 |
| 浏览器 → daemon | `terminal_input` | 用户键入 |
| 浏览器 → daemon | `resize` | 终端尺寸变更 |
| 浏览器 → daemon | `prompt_response` | 用户回复提示 |

DataChannel 使用 reliable 有序模式，终端数据不能丢包乱序。消息格式与现有 `protocol.zig` 定义一致。

### 信令消息（新增，走信令服务器 WebSocket）

| 方向 | 类型 | 说明 |
|------|------|------|
| daemon → 信令 | `register` | 注册 daemon，携带 pairing_code |
| 浏览器 → 信令 | `join` | 加入 pairing_code 对应的房间 |
| 浏览器 → 信令 | `auth` | 发送 setup_token 或 session_token |
| daemon → 信令 | `auth_result` | 认证结果 |
| 双向经信令 | `sdp_offer` / `sdp_answer` | SDP 交换 |
| 双向经信令 | `ice_candidate` | ICE candidate 交换 |

## libdatachannel 集成

### 依赖方式

通过 `build.zig` 链接 libdatachannel C 库：

```zig
exe.linkSystemLibrary("datachannel");
exe.linkLibC();
```

### Zig 绑定层 (`src/rtc.zig`)

```
RtcPeer
  ├─ init(config: RtcConfig)          // 创建 peer connection，配置 STUN/TURN
  ├─ setRemoteDescription(sdp)        // 设置远端 SDP
  ├─ localDescription() -> []const u8  // 获取本地 SDP
  ├─ addRemoteCandidate(candidate)     // 添加远端 ICE candidate
  ├─ createDataChannel(label)          // 创建 DataChannel
  ├─ send(data: []const u8)            // 通过 DataChannel 发送
  ├─ onMessage(callback)               // 注册消息回调
  ├─ onStateChange(callback)           // 连接状态变化回调
  └─ deinit()                          // 释放资源

RtcConfig
  ├─ stun_server: "stun:stun.l.google.com:19302"
  └─ turn_server: "turn:user:pass@turn.example.com:3478"
```

### 回调线程模型

libdatachannel 的回调在其内部线程触发，不能直接操作 SessionManager。

方案：回调将消息写入线程安全队列，主线程 poll 该队列处理。

```
libdatachannel 内部线程          主事件循环
        │                           │
  onMessage(data)                   │
        │                           │
        ├──► 写入 MessageQueue ──►  poll 读取
        │                           │
        │                      解析 JSON → dispatch 到 SessionManager
```

### 数据发送路径

```
PTY output → ioRelay 读取 → protocol.encodeTerminalOutput() → RtcPeer.send()
```

## 信令服务器设计

### 项目结构

独立 Go 项目，放在 `signal/` 目录下。

```
signal/
  ├─ main.go          // 入口，HTTP server + WebSocket upgrade
  ├─ room.go          // 房间管理，配对逻辑
  ├─ go.mod
  └─ static/          // 前端构建产物
```

### 核心逻辑

- WebSocket 连接进来，第一条消息决定角色：
  - `{ type: "register", pairing_code: "abc123" }` → 创建房间，标记为 daemon
  - `{ type: "join", pairing_code: "abc123" }` → 加入房间，标记为 browser
- 后续消息原样转发给房间内另一方

### 房间规则

- 一个 pairing_code 对应一个房间，最多 2 个参与者
- daemon 断开 → 房间销毁，通知浏览器
- 浏览器断开 → 通知 daemon，房间保留
- 10 分钟无活动 → 房间自动清理
- pairing_code 由 daemon 生成，6 位字母数字

### 部署

单二进制 `go build -o kite-signal`。前端静态文件通过 Go embed 嵌入或放 `static/` 目录。

## STUN/TURN 配置

- **STUN**：使用公共服务器 `stun:stun.l.google.com:19302`
- **TURN**：自建 coturn 部署在公网 VPS 上，作为 P2P 打洞失败时的 fallback
- STUN/TURN 地址作为 daemon 启动参数或配置文件提供

## 断线重连与错误处理

| 场景 | 检测方式 | 处理 |
|------|---------|------|
| DataChannel 断开 | `onStateChange` 回调 | 浏览器通过信令重新发起 WebRTC 握手 |
| daemon ↔ 信令断开 | WebSocket close/心跳超时 | daemon 自动重连，重新注册同一 pairing code |
| 浏览器 ↔ 信令断开 | WebSocket close | 浏览器自动重连，用 session_token 重新认证 |
| 信令服务器宕机 | 两端 WebSocket 都断 | 已建立的 DataChannel 不受影响 |
| daemon 重启 | DataChannel 断 + 信令断 | 需重新扫码配对 |

### 心跳

- daemon ↔ 信令服务器：每 30 秒 WebSocket ping/pong
- DataChannel：每 10 秒 `{ type: "ping" }`，5 秒无 pong 视为断开

### 重连流程

DataChannel 断开后，浏览器进入"重连中"UI 状态。如果信令 WebSocket 仍在，直接发起新 WebRTC 握手；否则先重连信令。握手成功后 daemon 发送 `sessions_sync` 和 RingBuffer 终端快照恢复显示。

## 各组件改动范围

### 信令服务器（新建）

Go 项目 `signal/`，约 200-300 行代码。

### Kite daemon（Zig，改动）

| 文件 | 改动 |
|------|------|
| `src/http.zig` | **删除** |
| `src/ws.zig` | **删除** |
| `src/web.zig` | **删除** |
| `src/rtc.zig` | **新增**。libdatachannel Zig 绑定，管理 peer connection 和 DataChannel |
| `src/signal_client.zig` | **新增**。信令服务器 WebSocket 客户端 |
| `src/auth.zig` | **小改**。认证通过信令通道执行 |
| `src/protocol.zig` | **小改**。添加信令消息编码 |
| `src/session_manager.zig` | **小改**。`ioRelay` broadcast 目标从 WsBroadcaster 换成 DataChannel |
| `src/main.zig` | **改动**。移除 HTTP 线程，添加信令客户端 + libdatachannel 初始化 |
| `build.zig` | **改动**。添加 libdatachannel 依赖链接 |

### 前端（Svelte，改动）

| 文件 | 改动 |
|------|------|
| `web/src/lib/ws.ts` | **重写**为 `webrtc.ts`，用 RTCPeerConnection + DataChannel |
| `web/src/lib/api.ts` | **删除**。会话管理走 DataChannel 消息 |
| `web/src/lib/auth.ts` | **改动**。认证通过信令 WebSocket 完成 |
| `web/src/lib/signal.ts` | **新增**。信令服务器 WebSocket 客户端 |
| `web/src/stores/sessions.ts` | **几乎不变**。消息源从 WebSocket 换成 DataChannel，格式不变 |
| `web/src/App.svelte` | **小改**。启动流程：信令 → 认证 → WebRTC → DataChannel → UI |

### 前端通信层接口

```typescript
// signal.ts
class SignalClient {
  connect(url: string, pairingCode: string)
  sendAuth(token: string)
  sendSdp(sdp: RTCSessionDescription)
  sendIceCandidate(candidate: RTCIceCandidate)
  onMessage(handler)
}

// webrtc.ts — 替代 ws.ts，对外接口一致
class RtcManager {
  sendTerminalInput(data, sessionId)
  sendResize(cols, rows, sessionId)
  sendPromptResponse(text, sessionId)
  onMessage(handler): () => void
}

export const rtc = new RtcManager();
```

`stores/sessions.ts` 只需把 `ws.onMessage` 换成 `rtc.onMessage`。

### 前端页面流程

```
打开页面
  ├─ 有 session_token？ → 连信令 → 认证 → WebRTC → 主界面
  ├─ URL 有 pairing_code？ → 连信令 → 等 setup_token → 认证 → WebRTC → 主界面
  └─ 都没有 → 显示"请扫码或输入配对码"
```
