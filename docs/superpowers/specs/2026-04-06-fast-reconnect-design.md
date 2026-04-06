# Fast Reconnect: ICE Restart + Parallel Recovery

## Problem

When the phone locks or switches networks, the WebRTC DataChannel drops. Current behavior destroys the entire PeerConnection and waits for a full signaling round-trip to re-establish, taking 5-10+ seconds. Terminal state is lost until a fresh `request_snapshot` completes after re-authentication.

## Goal

Minimize reconnection time to near-zero for lock-screen scenarios and ~1-2s for network switches. No need to replay missed messages; recovering the latest terminal state is sufficient.

## Design

### Trigger: `visibilitychange`

The browser listens for the page transitioning from `hidden` to `visible` (phone unlock). This fires immediately and is the fastest detection signal available.

### Three-path parallel recovery

On `visibilitychange` (hidden -> visible), fire all three paths simultaneously:

1. **Probe existing DC** — send `ping` through the DataChannel and `request_sync` (bets on DC still being alive). If DC responds, recovery is instant (~0ms).
2. **ICE restart** — call `pc.createOffer({ iceRestart: true })` and relay the new SDP through the signal server. This re-negotiates ICE candidates on the existing PeerConnection without rebuilding DTLS. Expected recovery: ~1-2s.
3. **Signal keepalive** — if the signal WebSocket itself is dead, its reconnect + re-join runs in parallel.

The first path that succeeds triggers state sync. The others are harmlessly ignored or cancelled.

### Fallback

If none of the three paths succeed within 15 seconds, fall back to the current full-rebuild logic: destroy PeerConnection, wait for `member_joined` via signal, create new PC + DC, re-authenticate.

### State sync after recovery

When the DataChannel becomes usable again (any path):

- **Browser** sends `{ "type": "request_sync" }` (new message type).
- **Daemon** responds with `sessions_sync` (full session list with state, prompts, tasks, subagents, activity) + terminal snapshot for active sessions.
- **Browser** overwrites local state and resets terminal with the snapshot.

### Authentication handling

- **ICE restart recovery**: DTLS session is reused, no re-authentication needed. The daemon tracks `authenticated: bool` per `RtcPeer`. If `authenticated == true` when DC re-opens, `request_sync` is honored without auth.
- **Full rebuild**: Goes through the existing auth flow (unchanged).
- **Probe success**: DC was never down, auth state unchanged.

### Signal client improvements (browser)

- Add ping/pong heartbeat (15s interval, 30s timeout) for faster dead-connection detection.
- Auto re-join topic after WebSocket reconnect (daemon already does this, browser doesn't).
- Buffer ICE restart offers during signal disconnection; send immediately on reconnect.

### Daemon-side changes

- **`RtcPeer`**: Add `authenticated: bool` field. Set to `true` after successful auth. On DC re-open, if `authenticated`, auto-send state sync.
- **`handleRelayPayload`**: No changes needed — `setRemoteDescription` on an existing PC with an ICE restart offer is already handled correctly by libdatachannel.
- **`handleDataChannelMessage`**: Add handler for `request_sync` message type — calls `sendSessionsSync` + `sendTerminalSnapshots`. Since the current architecture broadcasts to all peers (no per-peer send), this is fine — other connected peers receiving a redundant sync is harmless.
- **`onStateChange`**: Do NOT clean up peer on `disconnected`/`failed` — keep peer alive for ICE restart. Only clean up on explicit `member_left` from signal.

### Browser-side changes

**`webrtc.ts`:**
- Replace `handlePeerLeft()` on `disconnected`/`failed` with the three-path parallel recovery.
- Add `visibilitychange` listener that triggers parallel recovery.
- Add `request_sync` sender after DC recovery.
- Add 15s timeout for fallback to full rebuild.
- Track `iceRestarting: boolean` to avoid duplicate restart attempts.

**`signal.ts`:**
- Add ping/pong heartbeat.
- Auto re-join after reconnect.
- Add offer buffer for signal-down scenarios.

### New protocol message

```
Browser -> Daemon: { "type": "request_sync" }
```

Daemon responds with existing `sessions_sync` + `terminal_output` messages (same as post-auth flow).

## Files to modify

| File | Change |
|------|--------|
| `web/src/lib/webrtc.ts` | Parallel recovery logic, `visibilitychange` listener, `request_sync`, ICE restart |
| `web/src/lib/signal.ts` | Heartbeat, auto re-join, offer buffering |
| `web/src/App.svelte` | Handle `request_sync` response (reset terminal state) |
| `src/rtc.zig` | Add `authenticated` field to `RtcPeer` |
| `src/main.zig` | Handle `request_sync` message, set `authenticated` on auth success, auto-sync on DC re-open |
| `src/protocol.zig` | (Optional) Add `encodeRequestSync` if needed |

## Non-goals

- Incremental diff sync (full snapshot is fine for now)
- Replaying missed messages during disconnection
- UDP transport (browsers can't do raw UDP)
- Client-side input prediction (Mosh-style local echo)
