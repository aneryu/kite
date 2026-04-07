# Reconnect Speed Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speed up WebRTC and Signal connection/reconnection across all scenarios by tuning timeouts and adding parallel recovery paths.

**Architecture:** Pure frontend parameter changes and logic tweaks in 3 TypeScript files. No backend changes. Signal reconnects faster with lower delays; WebRTC detects failures sooner with shorter ping/pong cycles; disconnected state triggers immediate ICE restart; visibility restore does parallel probing; signal reconnect uses ICE restart instead of full peer rebuild.

**Tech Stack:** TypeScript, WebRTC API, WebSocket

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `web/src/lib/signal.ts` | Modify | Reduce reconnect delays and heartbeat timeouts |
| `web/src/lib/webrtc.ts` | Modify | Reduce ping/recovery timeouts, improve disconnect/visibility handling, add `hasActivePeer()` and `restartOrRebuild()` |
| `web/src/lib/connection.ts` | Modify | Use `restartOrRebuild()` instead of `startWebRTC()` in `setupTransports()` |

---

### Task 1: Signal parameter tuning

**Files:**
- Modify: `web/src/lib/signal.ts`

- [ ] **Step 1: Update reconnect delays**

In `signal.ts`, change the two class properties:

```typescript
// OLD (lines 23-24):
  private reconnectDelay = 2000;
  private maxReconnectDelay = 30000;

// NEW:
  private reconnectDelay = 500;
  private maxReconnectDelay = 5000;
```

- [ ] **Step 2: Update heartbeat constants**

```typescript
// OLD (lines 33-34):
  private readonly PING_INTERVAL = 15_000;
  private readonly PONG_TIMEOUT = 30_000;

// NEW:
  private readonly PING_INTERVAL = 8_000;
  private readonly PONG_TIMEOUT = 10_000;
```

- [ ] **Step 3: Update reconnect success reset value**

In the `connect()` method, the `onopen` handler resets `this.reconnectDelay = 2000`. Change to match the new initial:

```typescript
// OLD (line 61):
        this.reconnectDelay = 2000;

// NEW:
        this.reconnectDelay = 500;
```

- [ ] **Step 4: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add web/src/lib/signal.ts
git commit -m "perf: reduce signal reconnect delays and heartbeat timeouts"
```

---

### Task 2: WebRTC parameter tuning

**Files:**
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Update ping interval**

In the `startPing()` method, change the interval:

```typescript
// OLD (line 377):
    this.pingInterval = window.setInterval(() => {
      this.sendRaw({ type: 'ping' });
    }, 10_000);

// NEW:
    this.pingInterval = window.setInterval(() => {
      this.sendRaw({ type: 'ping' });
    }, 5_000);
```

- [ ] **Step 2: Update recovery timeout**

In `startRecovery()`, change the fallback timeout:

```typescript
// OLD (line 251):
    this.recoveryTimeout = window.setTimeout(() => {
      if (this.recovering) {
        console.log('[RTC] Recovery timeout, falling back to full rebuild');
        this.cancelRecovery();
        this.fullRebuild();
      }
    }, 15_000);

// NEW:
    this.recoveryTimeout = window.setTimeout(() => {
      if (this.recovering) {
        console.log('[RTC] Recovery timeout, falling back to full rebuild');
        this.cancelRecovery();
        this.fullRebuild();
      }
    }, 5_000);
```

- [ ] **Step 3: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "perf: reduce WebRTC ping interval and recovery timeout"
```

---

### Task 3: Immediate ICE restart on disconnect, full rebuild on failed

**Files:**
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Update `onconnectionstatechange` handler**

In `startWebRTC()`, replace the `onconnectionstatechange` handler:

```typescript
// OLD (lines 203-211):
    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'disconnected' || state === 'failed') {
        this.startRecovery();
      } else if (state === 'connected' && this.recovering) {
        // ICE restart succeeded at transport level, wait for DC to re-open
      }
    };

// NEW:
    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'failed') {
        // ICE agent is terminal — full rebuild is the only option
        this.cancelRecovery();
        this.fullRebuild();
      } else if (state === 'disconnected') {
        // Immediately attempt ICE restart, with recovery timer as fallback
        if (this.signal?.isConnected() && this.daemonMemberID) {
          this.attemptIceRestart();
        }
        this.startRecovery();
      } else if (state === 'connected' && this.recovering) {
        // ICE restart succeeded at transport level, wait for DC to re-open
      }
    };
```

- [ ] **Step 2: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "perf: immediate ICE restart on disconnect, direct rebuild on failed"
```

---

### Task 4: Parallel probing on visibility restore

**Files:**
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Update visibility handler**

In `installVisibilityHandler()`, replace the handler logic:

```typescript
// OLD (lines 322-329):
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        if (this.dc?.readyState === 'open') {
          this.sendRaw({ type: 'request_sync' });
        } else if (this.pc) {
          this.startRecovery();
        }
      }
    };

// NEW:
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        // Always probe liveness
        if (this.dc?.readyState === 'open') {
          this.sendRaw({ type: 'ping' });
          this.sendRaw({ type: 'request_sync' });
        }
        // If PC exists but not connected, do parallel recovery
        const pcState = this.pc?.connectionState;
        if (pcState && pcState !== 'connected') {
          if (this.signal?.isConnected() && this.daemonMemberID) {
            this.attemptIceRestart();
          }
          this.startRecovery();
        }
        // If signal is down, force reconnect in parallel
        if (this.signal && !this.signal.isConnected()) {
          this.signal.forceReconnect();
        }
      }
    };
```

- [ ] **Step 2: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "perf: parallel probing and ICE restart on visibility restore"
```

---

### Task 5: ICE restart instead of full rebuild after signal reconnect

**Files:**
- Modify: `web/src/lib/webrtc.ts`
- Modify: `web/src/lib/connection.ts`

- [ ] **Step 1: Add `hasActivePeer()` and `restartOrRebuild()` to WebRtcTransport**

In `webrtc.ts`, add these two methods after the existing `handleRelayedMessage()` method (around line 123):

```typescript
  hasActivePeer(): boolean {
    return this.pc !== null && this.pc.connectionState !== 'closed';
  }

  restartOrRebuild(): void {
    if (this.hasActivePeer()) {
      console.log('[RTC] Active peer exists, attempting ICE restart instead of full rebuild');
      this.attemptIceRestart();
    } else {
      this.startWebRTC();
    }
  }
```

- [ ] **Step 2: Update `setupTransports()` in connection.ts**

In `connection.ts`, in the `setupTransports()` function, change the call at the end:

```typescript
// OLD (line 151):
  webrtcTransport.startWebRTC();

// NEW:
  webrtcTransport.restartOrRebuild();
```

- [ ] **Step 3: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add web/src/lib/webrtc.ts web/src/lib/connection.ts
git commit -m "perf: use ICE restart instead of full rebuild after signal reconnect"
```

---

### Task 6: Final build and verify

- [ ] **Step 1: Full build**

```bash
cd web && npm run build
```

Expected: Build succeeds with no errors.

- [ ] **Step 2: Verify all parameter changes**

```bash
grep -n "reconnectDelay = " web/src/lib/signal.ts
grep -n "maxReconnectDelay = " web/src/lib/signal.ts
grep -n "PING_INTERVAL = " web/src/lib/signal.ts
grep -n "PONG_TIMEOUT = " web/src/lib/signal.ts
grep -n "5_000" web/src/lib/webrtc.ts
```

Expected:
- `reconnectDelay = 500`
- `maxReconnectDelay = 5000`
- `PING_INTERVAL = 8_000`
- `PONG_TIMEOUT = 10_000`
- WebRTC shows `5_000` for both ping interval and recovery timeout

- [ ] **Step 3: Verify `restartOrRebuild` is called in connection.ts**

```bash
grep -n "restartOrRebuild" web/src/lib/connection.ts web/src/lib/webrtc.ts
```

Expected: Method defined in webrtc.ts, called in connection.ts.
