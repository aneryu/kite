# Multi-Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a LAN direct-connect WebSocket transport alongside the existing WebRTC DataChannel, with a frontend TransportManager that auto-selects the fastest channel, and unify ICE server configuration.

**Architecture:** Backend adds a TCP/WebSocket server (`ws_server.zig`) on port 7891 (configurable). Frontend introduces a `Transport` interface with two implementations (`LanWebSocket`, `WebRtcTransport`) managed by `TransportManager`. ICE server config moves from hardcoded to CLI + config file + signaling delivery.

**Tech Stack:** Zig 0.15.2 (backend), Svelte 5 + TypeScript (frontend), libdatachannel (WebRTC), RFC 6455 (WebSocket)

---

## File Structure

### Backend (Zig)

| File | Action | Responsibility |
|------|--------|---------------|
| `src/ws_server.zig` | Create | TCP listener + WebSocket server, client management, send/receive |
| `src/net_info.zig` | Create | Detect LAN IP address via `getifaddrs()` |
| `src/rtc.zig` | Modify | Replace hardcoded STUN array with configurable `ice_servers` slice |
| `src/signal_client.zig` | Modify | Include `lan_ip`, `lan_port`, `ice_servers` in join message |
| `src/main.zig` | Modify | Add WS server thread, unified broadcast, `--ice-server` CLI flag, config persistence |

### Frontend (TypeScript)

| File | Action | Responsibility |
|------|--------|---------------|
| `web/src/lib/transport.ts` | Create | `Transport` interface + `TransportManager` class |
| `web/src/lib/lan-ws.ts` | Create | `LanWebSocket` transport implementation |
| `web/src/lib/webrtc.ts` | Modify | Refactor `RtcManager` → `WebRtcTransport` implementing `Transport` |
| `web/src/lib/signal.ts` | Modify | Extract `lan_ip`, `lan_port`, `ice_servers` from daemon join metadata |
| `web/src/App.svelte` | Modify | Replace `rtc` usage with `transport` (TransportManager) |
| `web/src/stores/sessions.ts` | Modify | Import from `transport` instead of `rtc` |
| `web/src/lib/types.ts` | Modify | Add `lan_ip`, `lan_port`, `ice_servers` fields to signal messages |

---

## Phase 1: LAN WebSocket + Transport Framework

### Task 1: Backend — LAN IP Detection (`net_info.zig`)

**Files:**
- Create: `src/net_info.zig`

- [ ] **Step 1: Create `net_info.zig` with `getLanIp()` function**

Uses `getifaddrs()` via C interop to find the first non-loopback IPv4 address.

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("arpa/inet.h");
    @cInclude("netinet/in.h");
});

/// Returns the first non-loopback IPv4 address as a string, or null.
pub fn getLanIp(buf: *[16]u8) ?[]const u8 {
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return null;
    defer c.freeifaddrs(ifap);

    var ifa = ifap;
    while (ifa) |a| : (ifa = a.ifa_next) {
        const sa = a.ifa_addr orelse continue;
        if (sa.sa_family != c.AF_INET) continue;
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(sa));
        const addr = sin.sin_addr;
        // Skip loopback (127.x.x.x)
        const first_byte: u8 = @truncate(addr.s_addr & 0xFF);
        if (first_byte == 127) continue;
        const result = c.inet_ntop(c.AF_INET, &addr, buf, 16);
        if (result == null) continue;
        // Find length of C string
        var len: usize = 0;
        while (len < 16 and buf[len] != 0) : (len += 1) {}
        return buf[0..len];
    }
    return null;
}
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: No errors related to `net_info.zig` (file is not yet imported by main)

- [ ] **Step 3: Commit**

```bash
git add src/net_info.zig
git commit -m "feat: add LAN IP detection via getifaddrs"
```

---

### Task 2: Backend — WebSocket Server (`ws_server.zig`)

**Files:**
- Create: `src/ws_server.zig`

This is a standalone TCP listener that accepts WebSocket connections, manages connected clients, and pipes messages into the existing `MessageQueue`.

- [ ] **Step 1: Create `ws_server.zig` — struct and init**

```zig
const std = @import("std");
const MessageQueue = @import("message_queue.zig").MessageQueue;
const logStderr = @import("log.zig").debug;

const max_clients = 8;

pub const WsClient = struct {
    stream: std.net.Stream,
    authenticated: bool = false,
    alive: bool = true,
};

pub const WsServer = struct {
    server: std.net.Server,
    clients: [max_clients]?WsClient = [_]?WsClient{null} ** max_clients,
    mutex: std.Thread.Mutex = .{},
    queue: *MessageQueue,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, port: u16, queue: *MessageQueue) !WsServer {
        const address = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
        var server = try address.listen(.{ .reuse_address = true });
        return WsServer{
            .server = server,
            .queue = queue,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.server.deinit();
    }
};
```

- [ ] **Step 2: Add WebSocket handshake**

Implement the HTTP/1.1 → WebSocket upgrade for incoming connections. The server side does NOT mask frames (per RFC 6455 — only clients mask).

```zig
    fn acceptLoop(self: *WsServer) void {
        while (true) {
            const conn = self.server.accept() catch continue;
            const slot = self.findFreeSlot() orelse {
                conn.stream.close();
                continue;
            };
            self.mutex.lock();
            self.clients[slot] = WsClient{ .stream = conn.stream };
            self.mutex.unlock();

            _ = std.Thread.spawn(.{}, clientThread, .{ self, slot }) catch {
                self.mutex.lock();
                self.clients[slot] = null;
                self.mutex.unlock();
                conn.stream.close();
            };
        }
    }

    fn findFreeSlot(self: *WsServer) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients, 0..) |c, i| {
            if (c == null) return i;
        }
        return null;
    }

    fn clientThread(self: *WsServer, slot: usize) void {
        defer {
            self.mutex.lock();
            if (self.clients[slot]) |*cl| cl.stream.close();
            self.clients[slot] = null;
            self.mutex.unlock();
        }

        // Read HTTP upgrade request
        var buf: [4096]u8 = undefined;
        const stream = self.clients[slot].?.stream;
        const n = stream.read(&buf) catch return;
        if (n == 0) return;
        const request = buf[0..n];

        // Extract Sec-WebSocket-Key
        const key = extractWsKey(request) orelse return;

        // Send upgrade response
        const accept_key = computeAcceptKey(key) catch return;
        self.sendUpgradeResponse(stream, &accept_key) catch return;

        // Read loop
        self.wsReadLoop(slot) catch {};
    }
```

Note: The actual WebSocket handshake requires computing the SHA-1 + base64 of the `Sec-WebSocket-Key` concatenated with the magic GUID. Implement `computeAcceptKey` and `sendUpgradeResponse` accordingly:

```zig
    const ws_magic = "258EAFA5-E914-47DA-95CA-5AB5DC7085B6";

    fn computeAcceptKey(ws_key: []const u8) ![28]u8 {
        var combined_buf: [60 + ws_magic.len]u8 = undefined;
        @memcpy(combined_buf[0..ws_key.len], ws_key);
        @memcpy(combined_buf[ws_key.len..][0..ws_magic.len], ws_magic);
        const combined = combined_buf[0 .. ws_key.len + ws_magic.len];

        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(combined, &hash, .{});

        var result: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&result, &hash);
        return result;
    }

    fn sendUpgradeResponse(self: *WsServer, stream: std.net.Stream, accept_key: *const [28]u8) !void {
        _ = self;
        var resp_buf: [256]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept_key.*},
        ) catch return error.BufferTooSmall;
        _ = try stream.write(resp);
    }

    fn extractWsKey(request: []const u8) ?[]const u8 {
        const needle = "Sec-WebSocket-Key: ";
        const start = std.mem.indexOf(u8, request, needle) orelse return null;
        const key_start = start + needle.len;
        const end = std.mem.indexOfPos(u8, request, key_start, "\r\n") orelse return null;
        return request[key_start..end];
    }
```

- [ ] **Step 3: Add WebSocket frame read/write (server-side)**

Server sends unmasked frames; reads masked frames from client.

```zig
    fn wsReadLoop(self: *WsServer, slot: usize) !void {
        while (true) {
            self.mutex.lock();
            const client = self.clients[slot] orelse {
                self.mutex.unlock();
                return;
            };
            const stream = client.stream;
            self.mutex.unlock();

            // Read frame header (2 bytes minimum)
            var hdr: [2]u8 = undefined;
            _ = try stream.readAll(&hdr);
            const opcode = hdr[0] & 0x0F;
            const masked = (hdr[1] & 0x80) != 0;
            var payload_len: usize = hdr[1] & 0x7F;

            if (payload_len == 126) {
                var ext: [2]u8 = undefined;
                _ = try stream.readAll(&ext);
                payload_len = (@as(usize, ext[0]) << 8) | ext[1];
            } else if (payload_len == 127) {
                var ext: [8]u8 = undefined;
                _ = try stream.readAll(&ext);
                payload_len = std.mem.readInt(u64, &ext, .big);
                if (payload_len > 1_048_576) return error.PayloadTooLarge;
            }

            var mask_key: [4]u8 = undefined;
            if (masked) {
                _ = try stream.readAll(&mask_key);
            }

            const payload = try self.allocator.alloc(u8, payload_len);
            defer self.allocator.free(payload);
            _ = try stream.readAll(payload);

            if (masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }

            switch (opcode) {
                0x1 => { // Text frame
                    try self.queue.push(payload);
                },
                0x8 => return, // Close
                0x9 => { // Ping → Pong
                    self.sendFrame(slot, 0x0A, payload) catch {};
                },
                else => {},
            }
        }
    }

    /// Send an unmasked WebSocket frame (server→client, no mask).
    pub fn sendFrame(self: *WsServer, slot: usize, opcode: u8, payload: []const u8) !void {
        self.mutex.lock();
        const client = self.clients[slot] orelse {
            self.mutex.unlock();
            return error.NotConnected;
        };
        const stream = client.stream;
        self.mutex.unlock();

        var hdr: [10]u8 = undefined;
        var hdr_len: usize = 0;
        hdr[0] = 0x80 | opcode; // FIN + opcode
        hdr_len += 1;

        if (payload.len < 126) {
            hdr[1] = @intCast(payload.len);
            hdr_len += 1;
        } else if (payload.len <= 65535) {
            hdr[1] = 126;
            hdr[2] = @intCast(payload.len >> 8);
            hdr[3] = @intCast(payload.len & 0xFF);
            hdr_len += 3;
        } else {
            hdr[1] = 127;
            std.mem.writeInt(u64, hdr[2..10], @intCast(payload.len), .big);
            hdr_len += 9;
        }

        _ = try stream.write(hdr[0..hdr_len]);
        _ = try stream.write(payload);
    }

    /// Send text to a specific client slot.
    pub fn sendText(self: *WsServer, slot: usize, text: []const u8) !void {
        try self.sendFrame(slot, 0x01, text);
    }

    /// Broadcast text to all connected clients (matches RTC broadcast behavior).
    pub fn broadcast(self: *WsServer, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.clients, 0..) |*maybe_client, i| {
            if (maybe_client.*) |_| {
                self.sendFrame(i, 0x01, text) catch {};
            }
        }
    }

    /// Mark all connected clients as authenticated.
    pub fn markAllAuthenticated(self: *WsServer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.clients) |*maybe_client| {
            if (maybe_client.*) |*cl| {
                cl.authenticated = true;
            }
        }
    }

    /// Mark a client as authenticated.
    pub fn setAuthenticated(self: *WsServer, slot: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.clients[slot]) |*cl| {
            cl.authenticated = true;
        }
    }

    /// Public entry point — call from a dedicated thread.
    pub fn run(self: *WsServer) void {
        self.acceptLoop();
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: No errors (file not yet imported by main)

- [ ] **Step 5: Commit**

```bash
git add src/ws_server.zig
git commit -m "feat: add WebSocket server for LAN direct connections"
```

---

### Task 3: Backend — Integrate WS Server into Main Event Loop

**Files:**
- Modify: `src/main.zig:18-24` (Config struct)
- Modify: `src/main.zig:128-153` (global state, broadcast)
- Modify: `src/main.zig:171-197` (CLI args)
- Modify: `src/main.zig:267-364` (event loop)
- Modify: `src/main.zig:81-126` (FileConfig, config read/write)

- [ ] **Step 1: Add `ws_port` to Config and FileConfig**

In `main.zig`, add `ws_port` field:

```zig
const Config = struct {
    command: []const u8 = "claude",
    attach_id: ?u64 = null,
    no_auth: bool = false,
    signal_url: []const u8 = "wss://kite.fun.dev/remote",
    turn_server: ?[]const u8 = null,
    ws_port: u16 = 7891,
};
```

- [ ] **Step 2: Add `--ws-port` CLI argument parsing**

In `runStart`, after the `--signal-url` block (~line 185-191), add:

```zig
        } else if (std.mem.eql(u8, args[i], "--ws-port")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--ws-port <PORT>", "start", "kite start --ws-port 7891");
                return;
            }
            config.ws_port = std.fmt.parseInt(u16, args[i + 1], 10) catch {
                const stderr_file = std.fs.File.stderr();
                _ = stderr_file.write("Invalid port number\n") catch {};
                return;
            };
            i += 1;
```

Also update the `start_opts` array for unknown option suggestions:

```zig
            const start_opts = [_][]const u8{ "--no-auth", "--signal-url", "--ws-port" };
```

- [ ] **Step 3: Import and initialize WS server, add `ws_queue`**

Near the queue initialization block (~line 267-275), add:

```zig
    const net_info = @import("net_info.zig");
    const WsServer = @import("ws_server.zig").WsServer;

    var ws_queue = MessageQueue.init(allocator);
    defer ws_queue.deinit();

    var lan_ip_buf: [16]u8 = undefined;
    const lan_ip = net_info.getLanIp(&lan_ip_buf);

    var ws_server = WsServer.init(allocator, config.ws_port, &ws_queue) catch |err| {
        logStderr("[kite] Failed to start WS server on port {d}: {}", .{ config.ws_port, err });
        // Non-fatal — continue without LAN WS
        null;
    };
    // (handle nullable ws_server below)
```

Actually, since Zig doesn't allow nullable for stack variables easily, use a separate bool:

```zig
    var ws_server: ?WsServer = WsServer.init(allocator, config.ws_port, &ws_queue) catch null;
    defer if (ws_server) |*ws| ws.deinit();

    if (ws_server != null) {
        logStderr("[kite] LAN WebSocket server listening on port {d}", .{config.ws_port});
        if (lan_ip) |ip| {
            try stdout.print("  LAN WebSocket: ws://{s}:{d}/ws\n", .{ ip, config.ws_port });
        }
    }
```

- [ ] **Step 4: Spawn WS server accept thread**

After the signal thread spawn (~line 297-301):

```zig
    if (ws_server) |*ws| {
        const ws_thread = std.Thread.spawn(.{}, WsServer.run, .{ws}) catch |err| {
            logStderr("[kite] Failed to spawn WS server thread: {}", .{err});
            ws_server = null;
        };
        if (ws_thread) |t| t.detach();
    }
```

Wait — `std.Thread.spawn` doesn't return nullable. It returns an error union. Fix:

```zig
    if (ws_server) |*ws| {
        _ = std.Thread.spawn(.{}, WsServer.run, .{ws}) catch |err| {
            logStderr("[kite] Failed to spawn WS server thread: {}", .{err});
        };
    }
```

- [ ] **Step 5: Unify broadcast — add global WS server pointer**

Add a module-level variable alongside `global_peers`:

```zig
var global_ws_server: ?*WsServer = null;
```

Update `initGlobalPeers` (rename to `initGlobalState` or just add the WS server):

In `broadcastViaRtc`, add WS broadcast:

```zig
fn broadcastViaRtc(data: []const u8) void {
    // Broadcast to WebRTC peers
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.send(data) catch {};
    }
    // Broadcast to LAN WebSocket clients
    if (global_ws_server) |ws| {
        ws.broadcast(data);
    }
}
```

Also update `markAllPeersAuthenticated` to include WS clients:

```zig
fn markAllPeersAuthenticated() void {
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.authenticated = true;
    }
    if (global_ws_server) |ws| {
        ws.markAllAuthenticated();
    }
}
```

Set `global_ws_server` in `runStart` after init:

```zig
    if (ws_server) |*ws| {
        global_ws_server = ws;
    }
```

- [ ] **Step 6: Process `ws_queue` in the main event loop**

In the main event loop (~line 314-364), after the `data_queue` processing block, add:

```zig
        // Process LAN WebSocket messages
        const ws_msgs = ws_queue.drain() catch break;
        if (ws_msgs.len > 0) {
            logStderr("[kite-loop] ws_queue: {d} messages", .{ws_msgs.len});
            defer ws_queue.freeBatch(ws_msgs);
            for (ws_msgs) |msg| {
                logStderr("[kite-loop] ws msg: {s}", .{msg[0..@min(msg.len, 200)]});
                handleDataChannelMessage(allocator, msg, &session_manager, &auth);
            }
        }
```

This reuses the same `handleDataChannelMessage` — the message format is identical.

- [ ] **Step 7: Build and test**

Run: `zig build 2>&1 | head -30`
Expected: Successful build

Run: `zig build run -- start --ws-port 7891 &; sleep 2; kill %1`
Expected: Output includes "LAN WebSocket: ws://..." (if on a LAN)

- [ ] **Step 8: Commit**

```bash
git add src/main.zig
git commit -m "feat: integrate LAN WebSocket server into daemon"
```

---

### Task 4: Backend — Include LAN Info + ICE Servers in Signal Join

**Files:**
- Modify: `src/signal_client.zig:114-123` (joinTopic)
- Modify: `src/signal_client.zig:12-26` (SignalClient struct)

- [ ] **Step 1: Add `lan_ip`, `lan_port`, `ice_servers_json` fields to SignalClient**

```zig
pub const SignalClient = struct {
    // ... existing fields ...
    lan_ip: ?[]const u8 = null,
    lan_port: u16 = 0,
    ice_servers_json: ?[]const u8 = null,  // pre-formatted JSON array string
};
```

- [ ] **Step 2: Update `joinTopic` to include new fields**

```zig
    pub fn joinTopic(self: *SignalClient) !void {
        var json_buf: std.ArrayList(u8) = .empty;
        defer json_buf.deinit(self.allocator);

        try json_buf.appendSlice(self.allocator, "{\"type\":\"join\",\"pairing_code\":\"");
        try json_buf.appendSlice(self.allocator, self.pairing_code);
        try json_buf.appendSlice(self.allocator, "\",\"role\":\"");
        try json_buf.appendSlice(self.allocator, self.role);
        try json_buf.appendSlice(self.allocator, "\"");

        if (self.lan_ip) |ip| {
            try json_buf.appendSlice(self.allocator, ",\"lan_ip\":\"");
            try json_buf.appendSlice(self.allocator, ip);
            try json_buf.writer(self.allocator).print("\",\"lan_port\":{d}", .{self.lan_port});
        }

        if (self.ice_servers_json) |ice| {
            try json_buf.appendSlice(self.allocator, ",\"ice_servers\":");
            try json_buf.appendSlice(self.allocator, ice);
        }

        try json_buf.appendSlice(self.allocator, "}");

        try self.sendText(json_buf.items);
    }
```

- [ ] **Step 3: Set the fields in `main.zig` before `joinTopic()`**

After `signal_client` creation (~line 281-291):

```zig
    signal_client.lan_ip = lan_ip;
    signal_client.lan_port = config.ws_port;
    // Build ICE servers JSON array
    const ice_json = buildIceServersJson(allocator, config) catch null;
    defer if (ice_json) |j| allocator.free(j);
    signal_client.ice_servers_json = ice_json;

    signal_client.joinTopic() catch |err| {
        // ... existing error handling ...
    };
```

Add helper function:

```zig
fn buildIceServersJson(allocator: std.mem.Allocator, config: Config) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "[");

    // Default STUN servers
    const rtc_mod = @import("rtc.zig");
    for (rtc_mod.default_ice_servers, 0..) |srv, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, srv);
        try buf.appendSlice(allocator, "\"");
    }

    // TURN server from config (legacy)
    if (config.turn_server) |turn| {
        if (rtc_mod.default_ice_servers.len > 0) try buf.appendSlice(allocator, ",");
        try buf.appendSlice(allocator, "\"");
        try buf.appendSlice(allocator, turn);
        try buf.appendSlice(allocator, "\"");
    }

    try buf.appendSlice(allocator, "]");
    return try allocator.dupe(u8, buf.items);
}
```

- [ ] **Step 4: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/signal_client.zig src/main.zig
git commit -m "feat: include LAN IP and ICE servers in signal join message"
```

---

### Task 5: Frontend — Transport Interface and TransportManager

**Files:**
- Create: `web/src/lib/transport.ts`

- [ ] **Step 1: Define Transport interface and TransportManager**

```typescript
import type { ServerMessage } from './types';

export type TransportState = 'connecting' | 'open' | 'closed';
export type MessageHandler = (msg: ServerMessage) => void;
export type StateHandler = (state: TransportState) => void;

export interface Transport {
  readonly name: string;
  readonly priority: number; // lower = higher priority
  connect(): Promise<void>;
  send(data: string): void;
  isOpen(): boolean;
  disconnect(): void;
  onMessage(handler: MessageHandler): () => void;
  onStateChange(handler: StateHandler): () => void;
}

export class TransportManager {
  private transports: Transport[] = [];
  private msgHandlers: MessageHandler[] = [];
  private activeTransportName: string | null = null;
  private unsubscribers: (() => void)[] = [];

  register(transport: Transport): void {
    this.transports.push(transport);
    this.transports.sort((a, b) => a.priority - b.priority);

    const unsubMsg = transport.onMessage((msg) => {
      // Only forward messages from the active transport
      if (transport.name === this.activeTransportName) {
        this.msgHandlers.forEach((h) => h(msg));
      }
    });

    const unsubState = transport.onStateChange(() => {
      this.updateActiveTransport();
    });

    this.unsubscribers.push(unsubMsg, unsubState);
  }

  async connectAll(): Promise<void> {
    await Promise.allSettled(this.transports.map((t) => t.connect()));
  }

  send(msg: Record<string, unknown>): void {
    const data = JSON.stringify(msg);
    const active = this.getActiveTransport();
    if (active) {
      active.send(data);
    } else {
      console.warn('[Transport] send DROPPED (no transport open):', msg.type);
    }
  }

  onMessage(handler: MessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  isConnected(): boolean {
    return this.transports.some((t) => t.isOpen());
  }

  activeTransport(): string | null {
    return this.activeTransportName;
  }

  disconnect(): void {
    this.unsubscribers.forEach((u) => u());
    this.unsubscribers = [];
    this.transports.forEach((t) => t.disconnect());
    this.transports = [];
    this.activeTransportName = null;
  }

  // Force a request_sync when switching transports
  requestSync(): void {
    this.send({ type: 'request_sync' });
  }

  private getActiveTransport(): Transport | null {
    for (const t of this.transports) {
      if (t.isOpen()) return t;
    }
    return null;
  }

  private updateActiveTransport(): void {
    const best = this.getActiveTransport();
    const newName = best?.name ?? null;
    if (newName !== this.activeTransportName) {
      const prev = this.activeTransportName;
      this.activeTransportName = newName;
      console.log(`[Transport] Active: ${prev} → ${newName}`);
      if (newName) {
        this.requestSync();
      }
    }
  }
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd web && npx tsc --noEmit 2>&1 | head -20`
Expected: No errors for transport.ts

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/transport.ts
git commit -m "feat: add Transport interface and TransportManager"
```

---

### Task 6: Frontend — LanWebSocket Transport

**Files:**
- Create: `web/src/lib/lan-ws.ts`

- [ ] **Step 1: Implement LanWebSocket**

```typescript
import type { ServerMessage } from './types';
import type { Transport, TransportState, MessageHandler, StateHandler } from './transport';

export class LanWebSocket implements Transport {
  readonly name = 'lan-ws';
  readonly priority = 1;

  private ws: WebSocket | null = null;
  private msgHandlers: MessageHandler[] = [];
  private stateHandlers: StateHandler[] = [];
  private lanIp: string;
  private lanPort: number;
  private token: string | null = null;
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;

  constructor(lanIp: string, lanPort: number) {
    this.lanIp = lanIp;
    this.lanPort = lanPort;
  }

  async connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const url = `ws://${this.lanIp}:${this.lanPort}/ws`;
      const timeout = setTimeout(() => {
        reject(new Error('LAN WS connect timeout'));
      }, 3000);

      try {
        this.ws = new WebSocket(url);
      } catch {
        clearTimeout(timeout);
        reject(new Error('LAN WS failed to create'));
        return;
      }

      this.ws.onopen = () => {
        clearTimeout(timeout);
        console.log('[LAN-WS] Connected');
        this.reconnectDelay = 2000;
        this.notifyState('open');
        if (this.token) {
          this.send(JSON.stringify({ type: 'auth', token: this.token }));
        }
        resolve();
      };

      this.ws.onmessage = (ev) => {
        try {
          const msg: ServerMessage = JSON.parse(ev.data);
          if (msg.type === 'pong') return;
          this.msgHandlers.forEach((h) => h(msg));
        } catch (e) {
          console.error('[LAN-WS] parse error:', e);
        }
      };

      this.ws.onclose = () => {
        console.log('[LAN-WS] Closed');
        this.notifyState('closed');
        this.scheduleReconnect();
      };

      this.ws.onerror = () => {
        clearTimeout(timeout);
        this.notifyState('closed');
        reject(new Error('LAN WS connection error'));
      };
    });
  }

  setToken(token: string): void {
    this.token = token;
    if (this.isOpen()) {
      this.send(JSON.stringify({ type: 'auth', token }));
    }
  }

  send(data: string): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    }
  }

  isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
  }

  onMessage(handler: MessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  onStateChange(handler: StateHandler): () => void {
    this.stateHandlers.push(handler);
    return () => { this.stateHandlers = this.stateHandlers.filter((h) => h !== handler); };
  }

  private notifyState(state: TransportState): void {
    this.stateHandlers.forEach((h) => h(state));
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => {
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
      });
    }, this.reconnectDelay);
  }
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd web && npx tsc --noEmit 2>&1 | head -20`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/lan-ws.ts
git commit -m "feat: add LAN WebSocket transport implementation"
```

---

### Task 7: Frontend — Refactor RtcManager into WebRtcTransport

**Files:**
- Modify: `web/src/lib/webrtc.ts`

This is the most delicate task. We refactor `RtcManager` to implement `Transport` while preserving all existing behavior (signaling, ICE restart, recovery, ping).

- [ ] **Step 1: Add Transport interface imports and implementation**

At the top of `webrtc.ts`:

```typescript
import type { ServerMessage } from './types';
import { SignalClient } from './signal';
import type { Transport, TransportState, MessageHandler, StateHandler } from './transport';
```

Rename class and add interface:

```typescript
export class WebRtcTransport implements Transport {
  readonly name = 'webrtc';
  readonly priority = 2;

  private pc: RTCPeerConnection | null = null;
  private dc: RTCDataChannel | null = null;
  private signal: SignalClient | null = null;
  private msgHandlers: MessageHandler[] = [];
  private stateHandlers: StateHandler[] = [];
  // ... rest of existing private fields unchanged ...
```

- [ ] **Step 2: Add `onStateChange` method and update state notifications**

Add the method:

```typescript
  onStateChange(handler: StateHandler): () => void {
    this.stateHandlers.push(handler);
    return () => { this.stateHandlers = this.stateHandlers.filter((h) => h !== handler); };
  }

  private notifyState(state: TransportState): void {
    this.stateHandlers.forEach((h) => h(state));
  }
```

In `startWebRTC`, update `dc.onopen`:

```typescript
    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
      this.notifyState('open');
      // ... rest of existing onopen logic ...
    };
```

In `dc.onclose`:

```typescript
    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
      this.notifyState('closed');
    };
```

In `teardownPeer`:

```typescript
  private teardownPeer(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];
    this.authenticated = false;
    this.notifyState('closed');
    this.handlers.forEach((h) => h({ type: 'disconnected' }));
  }
```

- [ ] **Step 3: Rename `onMessage` handler arrays for clarity**

The existing `handlers` array serves double duty (both app-level messages like `signal_connected`/`daemon_disconnected` AND data messages). For the Transport interface, `onMessage` should only be for data messages.

Keep the existing `handlers` as `appHandlers` for signal-level events, and use `msgHandlers` for Transport interface:

```typescript
  private appHandlers: MessageHandler[] = [];  // renamed from handlers
  private msgHandlers: MessageHandler[] = [];  // Transport interface

  // Transport interface
  onMessage(handler: MessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  // App-level events (signal_connected, daemon_disconnected, disconnected)
  onAppEvent(handler: MessageHandler): () => void {
    this.appHandlers.push(handler);
    return () => { this.appHandlers = this.appHandlers.filter((h) => h !== handler); };
  }
```

Update `dc.onmessage` to dispatch to `msgHandlers`:

```typescript
      this.dc.onmessage = (ev) => {
        try {
          const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
          const msg: ServerMessage = JSON.parse(raw);
          if (msg.type === 'pong') {
            if (this.recovering) this.onRecoverySuccess();
            return;
          }
          this.msgHandlers.forEach((h) => h(msg));
        } catch (e) {
          console.error('[RTC] DC message parse error:', e);
        }
      };
```

Update signal-level events to use `appHandlers`:

```typescript
          this.appHandlers.forEach((h) => h({ type: 'signal_connected' }));
          // ...
          this.appHandlers.forEach((h) => h({ type: 'daemon_disconnected' }));
          // ...  (in teardownPeer)
          this.appHandlers.forEach((h) => h({ type: 'disconnected' }));
```

- [ ] **Step 4: Add `send(data: string)` for Transport interface**

The Transport `send` takes a raw string. Add it alongside the existing `sendRaw`:

```typescript
  // Transport interface — send pre-serialized string
  send(data: string): void {
    if (this.dc?.readyState === 'open') {
      this.dc.send(data);
    } else {
      console.warn('[RTC] send DROPPED (dc not open)');
    }
  }
```

Keep `sendRaw` as internal helper:

```typescript
  private sendRaw(msg: Record<string, unknown>): void {
    this.send(JSON.stringify(msg));
  }
```

- [ ] **Step 5: Update `connect()` signature to accept config from signal**

Add `iceServers` parameter:

```typescript
  async connect(signalUrl?: string, pairingCode?: string, iceServers?: string[]): Promise<void> {
    if (iceServers) this.iceServers = iceServers;
    if (!signalUrl || !pairingCode) return; // Can't connect without signal
    this.signal = new SignalClient(signalUrl, pairingCode, 'browser');
    // ... rest unchanged ...
  }
```

Replace the `stunServer` property with `iceServers: string[]`:

```typescript
  private iceServers: string[] = ['stun:stun.l.google.com:19302'];
```

In `startWebRTC`:

```typescript
    const rtcIceServers: RTCIceServer[] = this.iceServers.map((s) => {
      if (s.startsWith('turn:')) {
        // Parse turn:user:pass@host:port
        const match = s.match(/^turn:([^:]+):([^@]+)@(.+)$/);
        if (match) {
          return { urls: `turn:${match[3]}`, username: match[1], credential: match[2] };
        }
      }
      return { urls: s };
    });
    this.pc = new RTCPeerConnection({ iceServers: rtcIceServers });
```

- [ ] **Step 6: Update the singleton export**

```typescript
export const webrtcTransport = new WebRtcTransport();
```

- [ ] **Step 7: Verify TypeScript compiles**

Run: `cd web && npx tsc --noEmit 2>&1 | head -20`
Expected: Errors in App.svelte and sessions.ts (they still import old `rtc`) — that's expected, we fix in next tasks.

- [ ] **Step 8: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "refactor: convert RtcManager to WebRtcTransport implementing Transport interface"
```

---

### Task 8: Frontend — Update Signal Client to Extract Daemon Metadata

**Files:**
- Modify: `web/src/lib/signal.ts`
- Modify: `web/src/lib/types.ts`

- [ ] **Step 1: Add daemon metadata fields to types.ts**

Add a new interface:

```typescript
export interface DaemonInfo {
  member_id: string;
  lan_ip?: string;
  lan_port?: number;
  ice_servers?: string[];
}
```

Also add these fields to `ServerMessage`:

```typescript
export interface ServerMessage {
  // ... existing fields ...
  member_id?: string;
  role?: string;
  members?: Array<{ id: string; role: string; lan_ip?: string; lan_port?: number; ice_servers?: string[] }>;
  lan_ip?: string;
  lan_port?: number;
  ice_servers?: string[];
  error?: string;
  payload?: Record<string, unknown>;
}
```

- [ ] **Step 2: Commit**

```bash
git add web/src/lib/types.ts
git commit -m "feat: add DaemonInfo type and signal metadata fields"
```

---

### Task 9: Frontend — Wire TransportManager into App.svelte

**Files:**
- Modify: `web/src/App.svelte`
- Modify: `web/src/stores/sessions.ts`

This is the integration task. Replace `rtc` singleton with `TransportManager`.

- [ ] **Step 1: Create and export a transport manager singleton**

Create `web/src/lib/connection.ts`:

```typescript
import { TransportManager } from './transport';
import { WebRtcTransport } from './webrtc';
import { LanWebSocket } from './lan-ws';
import { SignalClient } from './signal';
import type { DaemonInfo, ServerMessage } from './types';

export const transport = new TransportManager();
export const webrtcTransport = new WebRtcTransport();

let signalClient: SignalClient | null = null;
let lanWs: LanWebSocket | null = null;

type AppEventHandler = (msg: ServerMessage) => void;
const appEventHandlers: AppEventHandler[] = [];

export function onAppEvent(handler: AppEventHandler): () => void {
  appEventHandlers.push(handler);
  return () => { appEventHandlers.splice(appEventHandlers.indexOf(handler), 1); };
}

export async function connect(signalUrl: string, pairingCode: string): Promise<void> {
  signalClient = new SignalClient(signalUrl, pairingCode, 'browser');

  signalClient.onMessage((msg) => {
    switch (msg.type) {
      case 'joined': {
        let daemonInfo: DaemonInfo | null = null;
        if (msg.members) {
          const daemon = msg.members.find((m: { role: string }) => m.role === 'daemon');
          if (daemon) {
            daemonInfo = {
              member_id: daemon.id,
              lan_ip: daemon.lan_ip,
              lan_port: daemon.lan_port,
              ice_servers: daemon.ice_servers,
            };
          }
        }
        if (daemonInfo) {
          setupTransports(signalUrl, pairingCode, daemonInfo);
        }
        appEventHandlers.forEach((h) => h({ type: 'signal_connected' }));
        break;
      }
      case 'member_joined': {
        if (msg.role === 'daemon' && msg.member_id) {
          const info: DaemonInfo = {
            member_id: msg.member_id,
            lan_ip: msg.lan_ip,
            lan_port: msg.lan_port,
            ice_servers: msg.ice_servers,
          };
          setupTransports(signalUrl, pairingCode, info);
        }
        break;
      }
      case 'member_left': {
        appEventHandlers.forEach((h) => h({ type: 'daemon_disconnected' }));
        break;
      }
      case 'relay': {
        if (msg.payload) {
          webrtcTransport.handleRelayedMessage(msg.payload);
        }
        break;
      }
    }
  });

  await signalClient.connect();
}

function setupTransports(signalUrl: string, pairingCode: string, daemon: DaemonInfo): void {
  // Setup WebRTC transport (always)
  webrtcTransport.setSignal(signalClient!);
  webrtcTransport.setDaemonMemberID(daemon.member_id);
  if (daemon.ice_servers) {
    webrtcTransport.setIceServers(daemon.ice_servers);
  }
  webrtcTransport.startWebRTC();
  transport.register(webrtcTransport);

  // Setup LAN WebSocket transport (if LAN info available)
  if (daemon.lan_ip && daemon.lan_port) {
    lanWs = new LanWebSocket(daemon.lan_ip, daemon.lan_port);
    transport.register(lanWs);
    lanWs.connect().catch(() => {
      console.log('[LAN-WS] LAN connection failed (not on same network)');
    });
  }
}

export function authenticate(token: string): void {
  // Send auth via the active transport
  transport.send({ type: 'auth', token });
  // Also set token on LAN WS for future reconnects
  lanWs?.setToken(token);
  webrtcTransport.setStoredToken(token);
}

export function disconnect(): void {
  transport.disconnect();
  signalClient?.disconnect();
  signalClient = null;
  lanWs = null;
}

export function isConnected(): boolean {
  return transport.isConnected();
}
```

Note: This requires exposing some internal methods on `WebRtcTransport` (`setSignal`, `setDaemonMemberID`, `startWebRTC`, `handleRelayedMessage`, `setIceServers`, `setStoredToken`). These should be made public in the refactored `webrtc.ts`.

- [ ] **Step 2: Update `webrtc.ts` — expose required methods as public**

Make these methods public on `WebRtcTransport`:

```typescript
  setSignal(signal: SignalClient): void { this.signal = signal; }
  setDaemonMemberID(id: string): void { this.daemonMemberID = id; }
  setIceServers(servers: string[]): void { this.iceServers = servers; }
  setStoredToken(token: string): void { this.storedToken = token; this.authenticated = true; }
  handleRelayedMessage(payload: Record<string, unknown>): void { /* existing logic */ }
  startWebRTC(): void { /* existing logic, now public */ }
```

Remove the `connect()` method that creates its own SignalClient — that's now handled by `connection.ts`.

Remove the singleton export `export const rtc = new RtcManager()` — replaced by `connection.ts`.

- [ ] **Step 3: Update `sessions.ts` to use transport**

```typescript
import { transport } from './connection';
import type { SessionInfo, ServerMessage, QuestionInfo } from './types';

// ... SessionStore class unchanged ...

export const sessionStore = new SessionStore();
transport.onMessage((msg) => sessionStore.handleMessage(msg));
```

- [ ] **Step 4: Update `App.svelte` to use connection module**

Replace all `rtc` imports and calls:

```typescript
import { transport, connect, authenticate, disconnect, isConnected, onAppEvent } from '../lib/connection';
```

Key replacements:
- `rtc.connect(...)` → `connect(signalUrl, pairingCode)`
- `rtc.authenticate(token)` → `authenticate(token)`
- `rtc.onMessage(handler)` → `transport.onMessage(handler)` (for data) or `onAppEvent(handler)` (for signal_connected, daemon_disconnected)
- `rtc.isOpen()` → `isConnected()`
- `rtc.disconnect()` → `disconnect()`

- [ ] **Step 5: Update components that import rtc**

In each component, replace:
- `import { rtc } from '../lib/webrtc'` → `import { transport } from '../lib/connection'`
- `rtc.sendTerminalInput(data, sid)` → `transport.send({ type: 'terminal_input', data, session_id: sid })`
- `rtc.sendResize(cols, rows, sid)` → `transport.send({ type: 'resize', cols, rows, session_id: sid })`
- `rtc.sendPromptResponse(text, sid)` → `transport.send({ type: 'prompt_response', text, session_id: sid })`
- `rtc.createSession(cmd)` → `transport.send({ type: 'create_session', data: cmd || 'claude' })`
- `rtc.requestSnapshot(sid)` → `transport.send({ type: 'request_snapshot', session_id: sid })`
- `rtc.onMessage(handler)` → `transport.onMessage(handler)`

Files to update:
- `web/src/components/TerminalView.svelte`
- `web/src/components/SessionList.svelte`
- `web/src/components/SessionCard.svelte`
- `web/src/components/SessionDetail.svelte`

- [ ] **Step 6: Build frontend**

Run: `cd web && npm run build 2>&1 | tail -20`
Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add web/src/lib/connection.ts web/src/lib/webrtc.ts web/src/lib/types.ts \
        web/src/stores/sessions.ts web/src/App.svelte \
        web/src/components/TerminalView.svelte web/src/components/SessionList.svelte \
        web/src/components/SessionCard.svelte web/src/components/SessionDetail.svelte
git commit -m "feat: wire TransportManager into frontend, LAN WS + WebRTC dual transport"
```

---

## Phase 2: ICE Server Configuration

### Task 10: Backend — Configurable ICE Servers

**Files:**
- Modify: `src/rtc.zig:26-35` (stun_servers, RtcConfig)
- Modify: `src/main.zig:18-24` (Config)
- Modify: `src/main.zig:81-126` (FileConfig, read/write)
- Modify: `src/main.zig:171-197` (CLI args)
- Modify: `src/main.zig:467-500` (createPeerForMember)

- [ ] **Step 1: Rename hardcoded STUN array to `default_ice_servers` in `rtc.zig`**

```zig
pub const default_ice_servers = [_][]const u8{
    "stun:stun.qq.com:3478",
    "stun:stun.miwifi.com:3478",
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
};

pub const RtcConfig = struct {
    ice_servers: []const []const u8 = &default_ice_servers,
};
```

- [ ] **Step 2: Update `setupPeerConnection` to use `ice_servers` slice**

Replace the current logic (lines 65-85) that iterates `stun_servers` + optional `turn_server`:

```zig
    pub fn setupPeerConnection(self: *RtcPeer, config: RtcConfig) !void {
        const max_servers = 16;
        var servers: [max_servers][*c]const u8 = undefined;
        var server_count: c_int = 0;

        var bufs: [max_servers][:0]u8 = undefined;
        for (config.ice_servers) |srv| {
            if (server_count >= max_servers) break;
            const idx: usize = @intCast(server_count);
            bufs[idx] = try self.allocator.dupeZ(u8, srv);
            servers[idx] = bufs[idx].ptr;
            server_count += 1;
        }
        defer {
            for (0..@intCast(server_count)) |i| {
                self.allocator.free(bufs[i]);
            }
        }

        var rtc_config: c.rtcConfiguration = std.mem.zeroes(c.rtcConfiguration);
        rtc_config.iceServers = &servers;
        rtc_config.iceServersCount = server_count;

        const pc = c.rtcCreatePeerConnection(&rtc_config);
        if (pc < 0) return RtcError.RuntimeFailure;
        self.pc = pc;

        c.rtcSetUserPointer(pc, @ptrCast(self));
        try checkResult(c.rtcSetLocalDescriptionCallback(pc, onLocalDescription));
        try checkResult(c.rtcSetLocalCandidateCallback(pc, onLocalCandidate));
        try checkResult(c.rtcSetStateChangeCallback(pc, onStateChange));
        try checkResult(c.rtcSetDataChannelCallback(pc, onDataChannel));
    }
```

- [ ] **Step 3: Add `ice_servers` to Config and CLI**

In `main.zig` Config:

```zig
const Config = struct {
    command: []const u8 = "claude",
    attach_id: ?u64 = null,
    no_auth: bool = false,
    signal_url: []const u8 = "wss://kite.fun.dev/remote",
    turn_server: ?[]const u8 = null,  // keep for backward compatibility
    ws_port: u16 = 7891,
    extra_ice_servers: std.ArrayList([]const u8) = undefined,
};
```

Actually, using `std.ArrayList` in a struct with default init is tricky. Instead, use a simple slice approach: collect CLI args into a fixed array.

```zig
const Config = struct {
    command: []const u8 = "claude",
    attach_id: ?u64 = null,
    no_auth: bool = false,
    signal_url: []const u8 = "wss://kite.fun.dev/remote",
    turn_server: ?[]const u8 = null,
    ws_port: u16 = 7891,
    extra_ice: [8]?[]const u8 = [_]?[]const u8{null} ** 8,
    extra_ice_count: usize = 0,
};
```

In CLI parsing:

```zig
        } else if (std.mem.eql(u8, args[i], "--ice-server")) {
            if (i + 1 >= args.len) {
                cli.printMissingOption("--ice-server <URL>", "start", "kite start --ice-server <URL>");
                return;
            }
            if (config.extra_ice_count < config.extra_ice.len) {
                config.extra_ice[config.extra_ice_count] = args[i + 1];
                config.extra_ice_count += 1;
            }
            i += 1;
```

Update `start_opts`:

```zig
            const start_opts = [_][]const u8{ "--no-auth", "--signal-url", "--ws-port", "--ice-server" };
```

- [ ] **Step 4: Build merged ICE server list and pass to `createPeerForMember`**

Add a helper to build the full list:

```zig
fn buildIceServerList(allocator: std.mem.Allocator, config: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;

    // Defaults
    for (rtc_mod.default_ice_servers) |srv| {
        try list.append(allocator, srv);
    }

    // Legacy --turn-server
    if (config.turn_server) |turn| {
        try list.append(allocator, turn);
    }

    // --ice-server flags
    for (config.extra_ice[0..config.extra_ice_count]) |maybe| {
        if (maybe) |srv| {
            try list.append(allocator, srv);
        }
    }

    return list.toOwnedSlice(allocator);
}
```

Store the result and use it when creating peers. In `runStart`, after config parsing:

```zig
    const ice_servers = buildIceServerList(allocator, config) catch &rtc_mod.default_ice_servers;
```

Update `createPeerForMember` call site to pass the full list:

```zig
    const rtc_config = rtc_mod.RtcConfig{ .ice_servers = ice_servers };
```

- [ ] **Step 5: Add `ice_servers` to FileConfig and persistence**

Update `FileConfig`:

```zig
const FileConfig = struct {
    signal_url: []const u8 = "wss://kite.fun.dev/remote",
    pairing_code: []const u8 = "",
    setup_secret: []const u8 = "",
    // ice_servers loaded from config file are merged with defaults
};
```

Note: For simplicity, keep CLI `--ice-server` as the primary way to add servers. Config file persistence of ICE servers can be deferred — the defaults + CLI flags cover the immediate need.

- [ ] **Step 6: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: Clean build

Run: `zig build run -- start --ice-server "turn:user:pass@turn.example.com:3478" &; sleep 2; kill %1`
Expected: Starts successfully

- [ ] **Step 7: Commit**

```bash
git add src/rtc.zig src/main.zig
git commit -m "feat: configurable ICE servers via --ice-server CLI flag"
```

---

### Task 11: Frontend — Read ICE Servers from Signal, Remove Hardcoded STUN

**Files:**
- Modify: `web/src/lib/connection.ts`
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Already done in Task 9**

The `connection.ts` already reads `daemon.ice_servers` from the signal `member_joined` / `joined` messages and passes them to `webrtcTransport.setIceServers()`.

Verify that `webrtc.ts` no longer has `'stun:stun.l.google.com:19302'` as a hardcoded default when ICE servers are provided by the signal.

Update the default to be empty (no servers) when signal provides them:

```typescript
  private iceServers: string[] = [];  // Will be set from signal
```

But keep a fallback in `startWebRTC` if no servers were set:

```typescript
  startWebRTC(): void {
    // ...
    const servers = this.iceServers.length > 0
      ? this.iceServers
      : ['stun:stun.l.google.com:19302']; // Fallback if signal didn't provide servers
    const rtcIceServers: RTCIceServer[] = servers.map(/* ... */);
    // ...
  }
```

- [ ] **Step 2: Build frontend**

Run: `cd web && npm run build 2>&1 | tail -10`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/webrtc.ts web/src/lib/connection.ts
git commit -m "feat: frontend reads ICE servers from signal, removes hardcoded STUN"
```

---

### Task 12: End-to-End Integration Test

**Files:**
- No new files

- [ ] **Step 1: Build everything**

Run: `zig build && cd web && npm run build`
Expected: Clean builds on both

- [ ] **Step 2: Manual test — start daemon**

Run: `zig build run -- start`

Verify output includes:
- LAN WebSocket URL (e.g., `ws://192.168.x.x:7891/ws`)
- Pairing QR code / URL

- [ ] **Step 3: Manual test — open browser on same WiFi**

Open the pairing URL on phone browser. Verify:
- Signal connects
- LAN WebSocket connects (check browser console for `[LAN-WS] Connected`)
- Or WebRTC connects if not on same WiFi
- `[Transport] Active: null → lan-ws` (or `webrtc`) appears in console
- Authentication succeeds
- Session list loads
- Terminal output works

- [ ] **Step 4: Test failover**

Kill the LAN WS (e.g., `kill -9` the daemon briefly or block port 7891).
Verify: `[Transport] Active: lan-ws → webrtc` fallback happens automatically.

- [ ] **Step 5: Commit final state**

```bash
git add -A
git commit -m "feat: multi-transport complete — LAN WS + WebRTC with unified ICE config"
```
