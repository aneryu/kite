# Fast Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Minimize WebRTC reconnection time to near-zero for lock-screen and ~1-2s for network switches using ICE restart + parallel recovery.

**Architecture:** On `visibilitychange`, browser fires three parallel recovery paths (DC probe, ICE restart, signal reconnect). Daemon adds `authenticated` flag to peers so ICE-restarted connections skip re-auth. New `request_sync` message triggers full state push.

**Tech Stack:** Zig 0.15.2 (daemon), TypeScript/Svelte 5 (browser), libdatachannel (WebRTC), WebSocket (signaling)

---

### Task 1: Add `authenticated` field to `RtcPeer` (daemon)

**Files:**
- Modify: `src/rtc.zig:37-58` (RtcPeer struct and init)

- [ ] **Step 1: Add `authenticated` field to RtcPeer struct**

In `src/rtc.zig`, add the field to the struct definition and set it to `false` in `init`:

```zig
// In RtcPeer struct (after member_id field, line ~44):
authenticated: bool = false,
```

No change to `init()` needed — the default value of `false` applies.

- [ ] **Step 2: Build and run tests**

Run: `zig build test`
Expected: All tests pass (field addition is backwards-compatible).

- [ ] **Step 3: Commit**

```bash
git add src/rtc.zig
git commit -m "feat(rtc): add authenticated field to RtcPeer"
```

---

### Task 2: Handle `request_sync` message and set `authenticated` on auth (daemon)

**Files:**
- Modify: `src/main.zig:749-795` (handleDataChannelMessage and handleAuthMessage)

- [ ] **Step 1: Set `authenticated = true` on auth success in `handleAuthMessage`**

In `src/main.zig`, in `handleAuthMessage`, after broadcasting the success auth_result, set authenticated on all peers. Find the two places where auth succeeds (setup secret valid, session token valid) and add after each `broadcastViaRtc(result)`:

After the `sendSessionsSync` call in the setup-secret branch (around line 811):

```zig
        // Send sessions_sync + terminal snapshots after successful auth
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
        markAllPeersAuthenticated();
        return;
```

After the `sendSessionsSync` call in the session-token branch (around line 823):

```zig
        // Send sessions_sync + terminal snapshots after successful auth
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
        markAllPeersAuthenticated();
        return;
```

Also in the `auth.disabled` branch (around line 793):

```zig
        broadcastViaRtc(result);
        markAllPeersAuthenticated();
        return;
```

- [ ] **Step 2: Add `markAllPeersAuthenticated` helper**

Add this function near `broadcastViaRtc` in `src/main.zig`:

```zig
fn markAllPeersAuthenticated() void {
    var it = global_peers.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.authenticated = true;
    }
}
```

- [ ] **Step 3: Add `request_sync` handler in `handleDataChannelMessage`**

In `src/main.zig`, in `handleDataChannelMessage`, add a new branch after the `"ping"` handler (around line 786):

```zig
    } else if (std.mem.eql(u8, msg.@"type", "request_sync")) {
        logStderr("[kite-dc] request_sync received", .{});
        sendSessionsSync(allocator, session_manager, auth);
        sendTerminalSnapshots(allocator, session_manager);
    }
```

- [ ] **Step 4: Auto-sync on dc_open for authenticated peers**

In `src/main.zig`, in `handleRtcStateMessage`, update the `dc_open` branch (around line 604) to check authenticated status and auto-sync:

```zig
    } else if (std.mem.eql(u8, msg.@"type", "dc_open")) {
        logStderr("[kite-rtc] DataChannel opened for {s}!", .{msg.member_id orelse "unknown"});
        printStatus("  Browser connected\n");
        // If peer was previously authenticated (ICE restart), auto-sync
        if (msg.member_id) |mid| {
            if (global_peers.get(mid)) |peer| {
                if (peer.authenticated) {
                    logStderr("[kite-rtc] Peer {s} already authenticated, auto-syncing", .{mid});
                    sendSessionsSync(allocator, session_manager, auth);
                    sendTerminalSnapshots(allocator, session_manager);
                }
            }
        }
    }
```

This requires `handleRtcStateMessage` to have access to `session_manager` and `auth`. Update its signature and the call site.

Change the function signature (around line 539):

```zig
fn handleRtcStateMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
    signal_client: *SignalClient,
    session_manager: *SessionManager,
    auth: *Auth,
) void {
```

Update the call site in the main loop (around line 341):

```zig
                handleRtcStateMessage(allocator, msg, &signal_client, &session_manager, &auth);
```

- [ ] **Step 5: Build and run tests**

Run: `zig build test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat(main): handle request_sync, auto-sync on ICE restart dc_open"
```

---

### Task 3: Signal client heartbeat and auto re-join (browser)

**Files:**
- Modify: `web/src/lib/signal.ts`

- [ ] **Step 1: Add heartbeat ping/pong and auto re-join**

Replace the entire content of `web/src/lib/signal.ts` with:

```typescript
export interface SignalMessage {
  type: string;
  member_id?: string;
  role?: string;
  from?: string;
  to?: string;
  payload?: Record<string, unknown>;
  members?: Array<{ id: string; role: string }>;
  error?: string;
  [key: string]: unknown;
}

export type SignalMessageHandler = (msg: SignalMessage) => void;

export class SignalClient {
  private ws: WebSocket | null = null;
  private handlers: SignalMessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;
  private maxReconnectDelay = 30000;
  private url: string;
  private pairingCode: string;
  private role: string;
  public memberID: string = '';

  // Heartbeat state
  private pingInterval: number | null = null;
  private pongTimeout: number | null = null;
  private readonly PING_INTERVAL = 15_000;
  private readonly PONG_TIMEOUT = 30_000;

  // Buffered messages to send after reconnect
  private pendingSends: string[] = [];

  constructor(url: string, pairingCode: string, role: string = 'browser') {
    this.url = url;
    this.pairingCode = pairingCode;
    this.role = role;
  }

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws?.readyState === WebSocket.OPEN) { resolve(); return; }
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => {
        this.send({ type: 'join', pairing_code: this.pairingCode, role: this.role });
        this.reconnectDelay = 2000;
        this.startHeartbeat();
        this.flushPending();
        resolve();
      };
      this.ws.onmessage = (ev) => {
        try {
          const msg: SignalMessage = JSON.parse(ev.data);
          // Any message from server counts as "alive" — reset pong timeout
          this.resetPongTimeout();
          if (msg.type === 'joined' && msg.member_id) {
            this.memberID = msg.member_id;
          }
          this.handlers.forEach((h) => h(msg));
        } catch {}
      };
      this.ws.onclose = () => {
        this.stopHeartbeat();
        this.scheduleReconnect();
      };
      this.ws.onerror = () => {
        this.ws?.close();
        reject(new Error('WebSocket error'));
      };
    });
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => {
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
      });
    }, this.reconnectDelay);
  }

  /** Force an immediate reconnect attempt (used by recovery logic). */
  forceReconnect(): void {
    if (this.ws?.readyState === WebSocket.OPEN) return;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.connect().catch(() => {});
  }

  isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  onMessage(handler: SignalMessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  relay(to: string, payload: Record<string, unknown>): void {
    this.sendOrBuffer({ type: 'relay', to, payload });
  }

  broadcast(payload: Record<string, unknown>): void {
    this.sendOrBuffer({ type: 'broadcast', payload });
  }

  /** Send immediately if connected, otherwise buffer for after reconnect. */
  private sendOrBuffer(msg: Record<string, unknown>) {
    const json = JSON.stringify(msg);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(json);
    } else {
      this.pendingSends.push(json);
    }
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  private flushPending() {
    const msgs = this.pendingSends.splice(0);
    for (const json of msgs) {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(json);
      }
    }
  }

  // --- Heartbeat ---

  private startHeartbeat() {
    this.stopHeartbeat();
    this.pingInterval = window.setInterval(() => {
      this.send({ type: 'ping' });
    }, this.PING_INTERVAL);
    this.resetPongTimeout();
  }

  private stopHeartbeat() {
    if (this.pingInterval !== null) { clearInterval(this.pingInterval); this.pingInterval = null; }
    if (this.pongTimeout !== null) { clearTimeout(this.pongTimeout); this.pongTimeout = null; }
  }

  private resetPongTimeout() {
    if (this.pongTimeout !== null) clearTimeout(this.pongTimeout);
    this.pongTimeout = window.setTimeout(() => {
      console.warn('[Signal] No response in 30s, forcing reconnect');
      this.ws?.close();
    }, this.PONG_TIMEOUT);
  }

  disconnect() {
    this.stopHeartbeat();
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
    this.pendingSends = [];
  }
}
```

- [ ] **Step 2: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/signal.ts
git commit -m "feat(signal): add heartbeat, auto re-join, message buffering"
```

---

### Task 4: Parallel recovery logic in RtcManager (browser)

**Files:**
- Modify: `web/src/lib/webrtc.ts`

- [ ] **Step 1: Replace webrtc.ts with parallel recovery logic**

Replace the entire content of `web/src/lib/webrtc.ts` with:

```typescript
import type { ServerMessage } from './types';
import { SignalClient } from './signal';

type MessageHandler = (msg: ServerMessage) => void;

export class RtcManager {
  private pc: RTCPeerConnection | null = null;
  private dc: RTCDataChannel | null = null;
  private signal: SignalClient | null = null;
  private handlers: MessageHandler[] = [];
  private authenticated: boolean = false;
  private pingInterval: number | null = null;
  private pendingCandidates: { candidate: string; mid: string }[] = [];
  private remoteDescriptionSet = false;
  private daemonMemberID: string | null = null;
  private stunServer: string = 'stun:stun.l.google.com:19302';
  private storedToken: string | null = null;

  // Recovery state
  private recovering = false;
  private recoveryTimeout: number | null = null;
  private recoveryPongReceived = false;
  private visibilityHandler: (() => void) | null = null;

  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    if (stunServer) this.stunServer = stunServer;
    this.signal = new SignalClient(signalUrl, pairingCode, 'browser');

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'joined':
          this.daemonMemberID = null;
          if (msg.members) {
            const daemon = msg.members.find((m) => m.role === 'daemon');
            if (daemon) {
              this.daemonMemberID = daemon.id;
              if (!this.pc) {
                this.startWebRTC();
              }
              // If we're recovering and signal just reconnected, re-attempt ICE restart
              if (this.recovering && this.pc) {
                this.attemptIceRestart();
              }
            }
          }
          this.handlers.forEach((h) => h({ type: 'signal_connected' }));
          break;
        case 'member_joined':
          if (msg.role === 'daemon' && msg.member_id) {
            this.daemonMemberID = msg.member_id;
            if (this.recovering) {
              // Daemon came back — do full rebuild as part of recovery
              this.cancelRecovery();
              this.fullRebuild();
            } else if (!this.pc) {
              this.startWebRTC();
            }
          }
          break;
        case 'member_left':
          if (msg.member_id === this.daemonMemberID) {
            this.cancelRecovery();
            this.teardownPeer();
            this.daemonMemberID = null;
            this.handlers.forEach((h) => h({ type: 'daemon_disconnected' }));
          }
          break;
        case 'relay':
          if (msg.payload) {
            this.handleRelayedMessage(msg.payload);
          }
          break;
        case 'error':
          console.error('[RTC] Signal error:', msg.error);
          break;
      }
    });

    await this.signal.connect();
    this.installVisibilityHandler();
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  authenticate(token: string): void {
    this.storedToken = token;
    this.authenticated = true;
    this.sendRaw({ type: 'auth', token });
  }

  sendTerminalInput(data: string, sessionId: number): void {
    this.sendRaw({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number): void {
    this.sendRaw({ type: 'resize', cols, rows, session_id: sessionId });
  }

  requestSnapshot(sessionId: number): void {
    this.sendRaw({ type: 'request_snapshot', session_id: sessionId });
  }

  sendPromptResponse(text: string, sessionId: number): void {
    this.sendRaw({ type: 'prompt_response', text, session_id: sessionId });
  }

  createSession(command?: string): void {
    this.sendRaw({ type: 'create_session', data: command || 'claude' });
  }

  deleteSession(sessionId: number): void {
    this.sendRaw({ type: 'delete_session', session_id: sessionId });
  }

  isOpen(): boolean {
    return this.dc?.readyState === 'open';
  }

  disconnect(): void {
    this.cancelRecovery();
    this.removeVisibilityHandler();
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.signal?.disconnect();
    this.signal = null;
    this.authenticated = false;
    this.daemonMemberID = null;
  }

  // --- Parallel Recovery ---

  private startRecovery(): void {
    if (this.recovering) return;
    this.recovering = true;
    this.recoveryPongReceived = false;
    console.log('[RTC] Starting parallel recovery');

    // Path 1: Probe existing DC — send ping + request_sync
    if (this.dc?.readyState === 'open') {
      this.sendRaw({ type: 'ping' });
      this.sendRaw({ type: 'request_sync' });
    }

    // Path 2: ICE restart (needs signal to be connected)
    if (this.pc && this.signal?.isConnected() && this.daemonMemberID) {
      this.attemptIceRestart();
    }

    // Path 3: Ensure signal is alive (triggers re-join which leads to ICE restart)
    if (this.signal && !this.signal.isConnected()) {
      this.signal.forceReconnect();
    }

    // Fallback timeout: 15s → full rebuild
    this.recoveryTimeout = window.setTimeout(() => {
      if (this.recovering) {
        console.log('[RTC] Recovery timeout, falling back to full rebuild');
        this.cancelRecovery();
        this.fullRebuild();
      }
    }, 15_000);
  }

  private cancelRecovery(): void {
    this.recovering = false;
    if (this.recoveryTimeout !== null) {
      clearTimeout(this.recoveryTimeout);
      this.recoveryTimeout = null;
    }
  }

  private onRecoverySuccess(): void {
    if (!this.recovering) return;
    console.log('[RTC] Recovery succeeded');
    this.cancelRecovery();
    // Request full state sync
    this.sendRaw({ type: 'request_sync' });
  }

  private attemptIceRestart(): void {
    if (!this.pc || !this.signal || !this.daemonMemberID) return;
    console.log('[RTC] Attempting ICE restart');

    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    this.pc.createOffer({ iceRestart: true })
      .then((offer) => this.pc!.setLocalDescription(offer))
      .then(() => {
        if (this.pc?.localDescription && this.signal && this.daemonMemberID) {
          this.signal.relay(this.daemonMemberID, {
            type: 'sdp_offer',
            sdp: this.pc.localDescription.sdp,
            sdp_type: this.pc.localDescription.type,
          });
        }
      })
      .catch((err) => console.error('[RTC] ICE restart offer error:', err));
  }

  private fullRebuild(): void {
    console.log('[RTC] Full rebuild');
    this.teardownPeer();
    if (this.daemonMemberID) {
      this.startWebRTC();
    }
  }

  private teardownPeer(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];
    this.authenticated = false;
    this.handlers.forEach((h) => h({ type: 'disconnected' }));
  }

  // --- Visibility ---

  private installVisibilityHandler(): void {
    this.removeVisibilityHandler();
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        // Page just became visible (phone unlocked)
        // If DC is open, just probe. Otherwise start full recovery.
        if (this.dc?.readyState === 'open') {
          // DC might still work — send sync request optimistically
          this.sendRaw({ type: 'request_sync' });
        } else if (this.pc) {
          // DC is closed but PC exists — try recovery
          this.startRecovery();
        }
      }
    };
    document.addEventListener('visibilitychange', this.visibilityHandler);
  }

  private removeVisibilityHandler(): void {
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler);
      this.visibilityHandler = null;
    }
  }

  // --- WebRTC Setup ---

  private startWebRTC(): void {
    this.stopPing();
    this.dc?.close();
    this.pc?.close();
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    const iceServers: RTCIceServer[] = [{ urls: this.stunServer }];
    this.pc = new RTCPeerConnection({ iceServers });
    this.dc = this.pc.createDataChannel('kite', { ordered: true });

    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
      if (this.recovering) {
        this.onRecoverySuccess();
      } else if (this.storedToken) {
        // Initial connection or full rebuild — re-authenticate
        this.sendRaw({ type: 'auth', token: this.storedToken });
      }
    };

    this.dc.onmessage = (ev) => {
      try {
        const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
        const msg: ServerMessage = JSON.parse(raw);
        if (msg.type === 'pong') {
          if (this.recovering) this.onRecoverySuccess();
          return;
        }
        this.handlers.forEach((h) => h(msg));
      } catch (e) {
        console.error('[RTC] DC message parse error:', e);
      }
    };

    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
    };

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate && this.signal && this.daemonMemberID) {
        this.signal.relay(this.daemonMemberID, {
          type: 'ice_candidate',
          candidate: ev.candidate.candidate,
          mid: ev.candidate.sdpMid || '',
        });
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'disconnected' || state === 'failed') {
        // Don't destroy — start recovery instead
        this.startRecovery();
      } else if (state === 'connected' && this.recovering) {
        // ICE restart succeeded at the transport level
        // Wait for DC to re-open (handled in dc.onopen)
      }
    };

    this.pc.createOffer()
      .then((offer) => this.pc!.setLocalDescription(offer))
      .then(() => {
        if (this.pc?.localDescription && this.signal && this.daemonMemberID) {
          this.signal.relay(this.daemonMemberID, {
            type: 'sdp_offer',
            sdp: this.pc.localDescription.sdp,
            sdp_type: this.pc.localDescription.type,
          });
        }
      })
      .catch((err) => console.error('[RTC] Offer error:', err));
  }

  private handleRelayedMessage(payload: Record<string, unknown>): void {
    const type = payload.type as string;
    if (type === 'sdp_answer') {
      this.handleSdpAnswer(payload.sdp as string, payload.sdp_type as RTCSdpType);
    } else if (type === 'ice_candidate') {
      this.handleRemoteCandidate(payload.candidate as string, payload.mid as string);
    }
  }

  private async handleSdpAnswer(sdp: string, sdpType: RTCSdpType): Promise<void> {
    if (!this.pc) return;
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription({ sdp, type: sdpType }));
      this.remoteDescriptionSet = true;
      for (const c of this.pendingCandidates) {
        await this.pc.addIceCandidate(new RTCIceCandidate({ candidate: c.candidate, sdpMid: c.mid }));
      }
      this.pendingCandidates = [];
    } catch (err) {
      console.error('[RTC] setRemoteDescription error:', err);
    }
  }

  private async handleRemoteCandidate(candidate: string, mid: string): Promise<void> {
    if (!this.pc) return;
    if (!this.remoteDescriptionSet) {
      this.pendingCandidates.push({ candidate, mid });
      return;
    }
    try {
      await this.pc.addIceCandidate(new RTCIceCandidate({ candidate, sdpMid: mid }));
    } catch (err) {
      console.error('[RTC] addIceCandidate error:', err);
    }
  }

  private startPing(): void {
    this.stopPing();
    this.pingInterval = window.setInterval(() => {
      this.sendRaw({ type: 'ping' });
    }, 10_000);
  }

  private stopPing(): void {
    if (this.pingInterval !== null) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private sendRaw(msg: Record<string, unknown>): void {
    if (this.dc?.readyState === 'open') {
      this.dc.send(JSON.stringify(msg));
    } else {
      console.warn('[RTC] sendRaw DROPPED (dc not open):', msg.type);
    }
  }
}

export const rtc = new RtcManager();
```

- [ ] **Step 2: Build frontend**

Run: `cd web && npm run build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add web/src/lib/webrtc.ts
git commit -m "feat(webrtc): parallel recovery with ICE restart and visibilitychange"
```

---

### Task 5: Build and manual integration test

**Files:**
- No file changes — verification only

- [ ] **Step 1: Build the full project**

Run: `zig build`
Expected: Build succeeds.

- [ ] **Step 2: Build the web frontend**

Run: `cd web && npm run build`
Expected: Build succeeds.

- [ ] **Step 3: Run all Zig tests**

Run: `zig build test`
Expected: All tests pass.

- [ ] **Step 4: Commit the plan document**

```bash
git add docs/superpowers/plans/2026-04-06-fast-reconnect.md
git commit -m "docs: add fast reconnect implementation plan"
```
