# WebRTC Connection Speed Optimization Design

## Overview

Optimize WebRTC initial connection and reconnection speed across both frontend and backend. Three areas: RTCPeerConnection configuration, preconnect (warmup), and backend ICE server/transport optimization.

## 1. Frontend RTCPeerConnection Configuration

**File**: `web/src/lib/webrtc.ts` — `startWebRTC()` and `warmup()`

Change `new RTCPeerConnection()` config from just `{ iceServers }` to:

```ts
{
  iceServers: rtcIceServers,
  bundlePolicy: 'max-bundle',
  rtcpMuxPolicy: 'require',
  iceCandidatePoolSize: 4,
}
```

| Parameter | Effect |
|---|---|
| `iceCandidatePoolSize: 4` | Pre-gather candidates before `createOffer`, overlapping with other setup work |
| `bundlePolicy: 'max-bundle'` | Multiplex all streams onto one ICE transport, reducing connectivity checks from N channels to 1 |
| `rtcpMuxPolicy: 'require'` | Eliminate separate RTCP port probing, works with max-bundle |

Apply to both `startWebRTC()` (line 157) and new `warmup()` method.

## 2. Preconnect / Warmup

**Goal**: Overlap ICE candidate gathering with signal server join/daemon discovery, saving 0.3-1s on first connection.

**Time sequence comparison**:

```
Before: signal open → daemon info → create PC → gather → offer → SDP exchange → connected
After:  signal open → warmup PC+gather (parallel) → daemon info → offer immediately → SDP exchange → connected
```

### New method: `warmup()` in `WebRtcTransport`

- Called from `connection.ts` right after `signalClient.connect()` resolves
- Creates `RTCPeerConnection` with default STUN (`stun:relay.fun.dev:3478`) and full config (bundle, pool, etc.)
- Sets up `onicecandidate` callback to track gathered types, but does NOT send candidates yet (no daemon ID)
- Does NOT create DataChannel or send offer

### Modified: `startWebRTC()`

- If `this.pc` exists and `connectionState === 'new'` (warmed up PC), reuse it:
  - Update ICE servers if daemon provided different ones (requires teardown + recreate in that case, since ICE servers can't be changed on existing PC — but if servers match or daemon provides none, reuse)
  - Set all callbacks (connectionstate, datachannel, icecandidate with relay logic)
  - Create DataChannel
  - Create and send offer
- If no warmed-up PC, run the current full creation flow

### Trigger: `connection.ts`

```ts
await signalClient.connect();
webrtcTransport.warmup();  // NEW
webrtcTransport.installVisibilityHandler();
```

## 3. Backend ICE Server + Transport Optimization

### ICE server list: `src/rtc.zig`

Reduce from 4 to 2 servers:

| Server | Keep | Reason |
|---|---|---|
| `stun:relay.fun.dev:3478` | ✅ | Self-hosted, co-located with signal server, lowest latency |
| `stun:stun.qq.com:3478` | ✅ | Domestic (China) backup, good reachability |
| `stun:stun.miwifi.com:3478` | ❌ | Non-professional STUN, reliability unknown |
| `stun:stun.l.google.com:19302` | ❌ | Unreachable in China, timeout causes 5-10s delay |

### ICE server ordering: `src/main.zig`

`buildIceServerList()` currently appends user-defined servers after defaults. Reverse the order so user-defined servers (e.g. TURN with credentials via `--ice-server`) are first:

```
1. --ice-server (user-defined, tried first — e.g. TURN on relay.fun.dev)
2. default_ice_servers (built-in STUN fallback)
```

This ensures user-configured TURN servers (with guaranteed reachability) are tried before STUN candidates that require P2P hole-punching. ICE will connect via the first reachable path (TURN relay), then optimize to direct P2P if available.

### forceMediaTransport: `src/rtc.zig`

Enable `forceMediaTransport = true` in `rtcConfiguration`. This is the backend counterpart to frontend's `max-bundle` — forces reuse of media transport channel, reducing backend-side ICE channel count.

## Files to Modify

| File | Changes |
|---|---|
| `web/src/lib/webrtc.ts` | Add `warmup()` method; update `startWebRTC()` to reuse warmed PC and use full RTCPeerConnection config; extract shared config builder |
| `web/src/lib/connection.ts` | Call `webrtcTransport.warmup()` after signal connect |
| `src/rtc.zig` | Reduce `default_ice_servers` to 2; enable `forceMediaTransport` in `setupPeerConnection()` |
| `src/main.zig` | Reorder `buildIceServerList()`: user-defined first, defaults second |

## Expected Impact

| Metric | Before | After |
|---|---|---|
| ICE gathering | 1-5s (4 STUN servers, some unreachable) | 0.3-1s (2 reachable servers + pre-gathering) |
| ICE connectivity checks | Multiple channels | Single bundled channel |
| First connect (signal open → DC open) | 3-8s | 1-3s |
| Reconnect (ICE restart) | Already optimized (prior work) | Slightly faster due to fewer STUN servers |

## Out of Scope

- ICE-Lite (not available in libdatachannel C API)
- Aggressive Nomination (not available in libdatachannel C API)
- TURN server deployment (TURN credentials passed via `--ice-server`, no code changes needed)
- iceTransportPolicy changes (current `all` policy is correct — allows TURN-first then P2P optimization)
