# WebRTC Connection Speed Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optimize WebRTC initial connection and reconnection speed via RTCPeerConnection config, preconnect warmup, and backend ICE server/transport tuning.

**Architecture:** Frontend adds `bundlePolicy: 'max-bundle'`, `rtcpMuxPolicy: 'require'`, `iceCandidatePoolSize: 4` to all PC creation paths. A new `warmup()` method pre-creates the PeerConnection before daemon info arrives. Backend reduces STUN servers from 4→2, reorders ICE list to put user-defined servers first, and enables `forceMediaTransport`.

**Tech Stack:** TypeScript/Svelte (frontend), Zig 0.15.2 + libdatachannel (backend)

---

### Task 1: Backend — Reduce default ICE servers and enable forceMediaTransport

**Files:**
- Modify: `src/rtc.zig:26-31` (default_ice_servers)
- Modify: `src/rtc.zig:91-93` (rtcConfiguration in setupPeerConnection)

- [ ] **Step 1: Reduce default_ice_servers from 4 to 2**

In `src/rtc.zig`, replace:

```zig
pub const default_ice_servers = [_][]const u8{
    "stun:relay.fun.dev:3478",
    "stun:stun.qq.com:3478",
    "stun:stun.miwifi.com:3478",
    "stun:stun.l.google.com:19302",
};
```

With:

```zig
pub const default_ice_servers = [_][]const u8{
    "stun:relay.fun.dev:3478",
    "stun:stun.qq.com:3478",
};
```

- [ ] **Step 2: Enable forceMediaTransport**

In `src/rtc.zig`, in `setupPeerConnection()`, after setting `rtc_config.iceServersCount`, add:

```zig
var rtc_config: c.rtcConfiguration = std.mem.zeroes(c.rtcConfiguration);
rtc_config.iceServers = &servers;
rtc_config.iceServersCount = server_count;
rtc_config.forceMediaTransport = true;
```

- [ ] **Step 3: Build and run tests**

Run: `zig build test`
Expected: All tests pass (existing json escape test unaffected).

Run: `zig build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/rtc.zig
git commit -m "perf: reduce default ICE servers to 2, enable forceMediaTransport"
```

---

### Task 2: Backend — Reorder ICE server list (user-defined first)

**Files:**
- Modify: `src/main.zig:451-464` (buildIceServerList function)

- [ ] **Step 1: Reorder buildIceServerList**

In `src/main.zig`, replace the current `buildIceServerList` function:

```zig
fn buildIceServerList(allocator: std.mem.Allocator, config: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (rtc_mod.default_ice_servers) |srv| {
        try list.append(allocator, srv);
    }
    if (config.turn_server) |turn| {
        try list.append(allocator, turn);
    }
    for (config.extra_ice[0..config.extra_ice_count]) |maybe| {
        if (maybe) |srv| {
            try list.append(allocator, srv);
        }
    }
    return list.toOwnedSlice(allocator);
}
```

With:

```zig
fn buildIceServerList(allocator: std.mem.Allocator, config: Config) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    // User-defined servers first (TURN, custom STUN) — tried before defaults
    for (config.extra_ice[0..config.extra_ice_count]) |maybe| {
        if (maybe) |srv| {
            try list.append(allocator, srv);
        }
    }
    if (config.turn_server) |turn| {
        try list.append(allocator, turn);
    }
    // Built-in STUN servers as fallback
    for (rtc_mod.default_ice_servers) |srv| {
        try list.append(allocator, srv);
    }
    return list.toOwnedSlice(allocator);
}
```

- [ ] **Step 2: Build and verify**

Run: `zig build`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "perf: reorder ICE server list — user-defined servers first"
```

---

### Task 3: Frontend — RTCPeerConnection config optimization

**Files:**
- Modify: `web/src/lib/webrtc.ts:145-157` (startWebRTC PC creation)

- [ ] **Step 1: Extract shared config builder and update startWebRTC**

In `web/src/lib/webrtc.ts`, add a private helper method after the `storedToken` field declarations (around line 23):

```ts
  private buildPcConfig(servers?: string[]): RTCConfiguration {
    const iceServers: RTCIceServer[] = (servers && servers.length > 0
      ? servers
      : ['stun:relay.fun.dev:3478']
    ).map((s) => {
      if (s.startsWith('turn:')) {
        const match = s.match(/^turn:([^:]+):([^@]+)@(.+)$/);
        if (match) {
          return { urls: `turn:${match[3]}`, username: match[1], credential: match[2] };
        }
      }
      return { urls: s };
    });
    return {
      iceServers,
      bundlePolicy: 'max-bundle',
      rtcpMuxPolicy: 'require',
      iceCandidatePoolSize: 4,
    };
  }
```

- [ ] **Step 2: Update startWebRTC to use buildPcConfig**

In `startWebRTC()`, replace lines 145-157:

```ts
    const servers = this.iceServers.length > 0
      ? this.iceServers
      : ['stun:relay.fun.dev:3478'];
    const rtcIceServers: RTCIceServer[] = servers.map((s) => {
      if (s.startsWith('turn:')) {
        const match = s.match(/^turn:([^:]+):([^@]+)@(.+)$/);
        if (match) {
          return { urls: `turn:${match[3]}`, username: match[1], credential: match[2] };
        }
      }
      return { urls: s };
    });
    this.pc = new RTCPeerConnection({ iceServers: rtcIceServers });
```

With:

```ts
    this.pc = new RTCPeerConnection(this.buildPcConfig(this.iceServers));
```

- [ ] **Step 3: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds with no TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "perf: add bundlePolicy, rtcpMuxPolicy, iceCandidatePoolSize to RTCPeerConnection"
```

---

### Task 4: Frontend — Add warmup() method and modify startWebRTC to reuse warmed PC

**Files:**
- Modify: `web/src/lib/webrtc.ts` (add warmup method, modify startWebRTC)

- [ ] **Step 1: Add warmup() method**

In `web/src/lib/webrtc.ts`, add the `warmup()` method after `restartOrRebuild()` (after line 136):

```ts
  warmup(): void {
    if (this.pc) return;
    console.log('[RTC] Warming up PeerConnection');
    this.pc = new RTCPeerConnection(this.buildPcConfig());
    this.gatheredTypes.clear();
    this.gatheringDone = false;
    this.pc.onicecandidate = (ev) => {
      if (ev.candidate) {
        const ct = ev.candidate.type;
        if (ct) this.gatheredTypes.add(ct);
      } else {
        this.gatheringDone = true;
      }
    };
  }
```

- [ ] **Step 2: Modify startWebRTC to reuse warmed PC**

Replace the beginning of `startWebRTC()` (lines 138-158) with logic that reuses a warmed PC when available:

```ts
  startWebRTC(): void {
    this.stopPing();
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    const reuseWarmed = this.pc
      && this.pc.connectionState === 'new'
      && (this.iceServers.length === 0); // reuse only if daemon didn't provide custom servers

    if (!reuseWarmed) {
      this.dc?.close();
      this.pc?.close();
      this.pc = new RTCPeerConnection(this.buildPcConfig(this.iceServers));
      this.gatheredTypes.clear();
      this.gatheringDone = false;
    } else {
      console.log('[RTC] Reusing warmed PeerConnection');
    }

    this.dc = this.pc!.createDataChannel('kite', { ordered: true });
```

Everything after the DataChannel creation (onopen, onmessage, onclose, onicecandidate, onconnectionstatechange, createOffer) stays the same, but `onicecandidate` now replaces the warmup's minimal callback with the full one that relays candidates.

The rest of startWebRTC (from `this.dc.onopen = () => {` through the end) remains unchanged.

- [ ] **Step 3: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "perf: add warmup() preconnect, reuse warmed PC in startWebRTC"
```

---

### Task 5: Frontend — Wire warmup into connection.ts

**Files:**
- Modify: `web/src/lib/connection.ts:126-128`

- [ ] **Step 1: Call warmup after signal connect**

In `web/src/lib/connection.ts`, replace lines 126-128:

```ts
  await signalClient.connect();
  webrtcTransport.installVisibilityHandler();
```

With:

```ts
  await signalClient.connect();
  webrtcTransport.warmup();
  webrtcTransport.installVisibilityHandler();
```

- [ ] **Step 2: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds.

- [ ] **Step 3: Build full project**

Run: `zig build`
Expected: Build succeeds (backend + frontend unchanged since Task 2).

- [ ] **Step 4: Commit**

```bash
git add web/src/lib/connection.ts
git commit -m "perf: call warmup() after signal connect for preconnect"
```

---

### Task 6: Verify full build and manual test

- [ ] **Step 1: Run backend tests**

Run: `zig build test`
Expected: All tests pass.

- [ ] **Step 2: Build full project**

Run: `zig build`
Expected: Build succeeds.

- [ ] **Step 3: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds, no TypeScript errors.

- [ ] **Step 4: Manual verification checklist**

Start the server and verify in browser:
- PeerConnection is created with `bundlePolicy: 'max-bundle'` (check `pc.getConfiguration()` in devtools)
- `iceCandidatePoolSize: 4` is set
- Warmup PC is created immediately after signal connects (check `[RTC] Warming up PeerConnection` log)
- When daemon joins, warmed PC is reused if no custom ICE servers (check `[RTC] Reusing warmed PeerConnection` log)
- ICE candidates are gathered and connection establishes
- DataChannel opens and auth works
- ICE restart on disconnect still works
- Visibility recovery still works
