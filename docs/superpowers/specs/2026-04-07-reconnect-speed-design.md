# Connection & Reconnection Speed Optimization Design

## Overview

Optimize WebRTC and Signal connection/reconnection speed across all scenarios: first connect, background recovery, and network interruption recovery. Priority is speed over battery/bandwidth conservation.

## 1. Parameter Tuning

### Signal (`web/src/lib/signal.ts`)

| Parameter | Current | New |
|---|---|---|
| `reconnectDelay` (initial) | 2000ms | 500ms |
| `maxReconnectDelay` | 30000ms | 5000ms |
| `PING_INTERVAL` | 15000ms | 8000ms |
| `PONG_TIMEOUT` | 30000ms | 10000ms |

### WebRTC (`web/src/lib/webrtc.ts`)

| Parameter | Current | New |
|---|---|---|
| ping interval (`startPing`) | 10000ms | 5000ms |
| recovery timeout (`startRecovery`) | 15000ms | 5000ms |

## 2. Immediate ICE Restart on Disconnect

Current: `onconnectionstatechange` calls `startRecovery()` for both `disconnected` and `failed`, and recovery internally tries ICE restart alongside other paths.

New behavior:
- `disconnected` → immediately call `attemptIceRestart()` + start recovery timer (5s to full rebuild as fallback)
- `failed` → skip ICE restart, go straight to `fullRebuild()` (ICE agent is terminal in `failed` state)

## 3. Parallel Probing on Visibility Restore

Current `visibilitychange` → `visible` handler:
- DC open → send `request_sync`
- DC not open + PC exists → call `startRecovery()`

New behavior:
- DC open but PC connectionState not `connected` → send `ping` + `request_sync` on DC, simultaneously attempt ICE restart
- DC open and PC connectionState `connected` → send `ping` + `request_sync` (probe liveness)
- DC not open or PC null → full `startRecovery()` (which now also does immediate ICE restart)
- Signal disconnected → also call `signal.forceReconnect()` in parallel

## 4. ICE Restart Instead of Full Rebuild After Signal Reconnect

In `connection.ts`, the `joined` event handler calls `setupTransports(daemonInfo)` which calls `startWebRTC()` — this tears down and rebuilds the entire PeerConnection.

Optimization: In `setupTransports()`, if the WebRTC transport already has a PeerConnection (i.e., it was previously connected), attempt ICE restart instead of full rebuild. Only do full rebuild if there's no existing PC.

This requires exposing a method on `WebRtcTransport` to check if a PC exists and attempt ICE restart, vs. starting fresh.

Add to `WebRtcTransport`:
- `hasActivePeer(): boolean` — returns true if `this.pc !== null`
- `restartOrRebuild()` — if PC exists and connectionState is not `closed`, do ICE restart; otherwise do full `startWebRTC()`

In `connection.ts` `setupTransports()`, change:
- `webrtcTransport.startWebRTC()` → `webrtcTransport.restartOrRebuild()`

## Files to Modify

| File | Changes |
|---|---|
| `web/src/lib/signal.ts` | Change 4 constant values |
| `web/src/lib/webrtc.ts` | Change 2 constant values, update `onconnectionstatechange` logic, update `visibilitychange` handler, add `hasActivePeer()` and `restartOrRebuild()` methods |
| `web/src/lib/connection.ts` | Change `startWebRTC()` call to `restartOrRebuild()` in `setupTransports()` |

## Out of Scope

- Connection preconnect/prewarming
- ICE gathering timeout tuning
- Backend/signal server changes
- LAN WebSocket reconnection (already fast)
