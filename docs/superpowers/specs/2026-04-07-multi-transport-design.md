# Multi-Transport Design: LAN WebSocket + WebRTC DataChannel

## Overview

Kite currently uses a single WebRTC DataChannel for all data transfer between the phone browser and the kite daemon. This design adds a second data transport — a direct LAN WebSocket — and introduces a transport management framework that automatically selects the fastest available channel.

### Goals

- **Lower latency on LAN**: Direct WebSocket on the same WiFi eliminates STUN/TURN overhead (~1ms vs ~50-100ms)
- **Faster connection establishment**: LAN WS connects instantly (TCP handshake) while WebRTC needs 2-5s SDP negotiation
- **Higher reliability**: Two independent channels provide automatic failover
- **Unified ICE server management**: Backend-managed configuration, delivered to frontend via signaling

### Non-Goals

- Signal server data relay (server pressure concern)
- WebTransport/QUIC (deferred to future phase)
- Multi-device simultaneous control

## Architecture

```
Phone Browser
    │
    ├─ SignalClient (WS) ──→ Signal Server ──→ kite daemon
    │     (signaling only: SDP, ICE candidates, LAN discovery)
    │
    ├─ LanWebSocket ──→ kite HTTP server (ws://192.168.x.x:7890/ws)
    │     (priority 1, LAN only, instant connect)
    │
    └─ WebRTC DataChannel ──→ kite daemon (P2P via ICE)
          (priority 2, works across NAT)
```

### Transport Priority

| Priority | Transport | Scenario | Latency | Connect Speed |
|----------|-----------|----------|---------|---------------|
| 1 | LAN WebSocket | Same WiFi | ~1ms | Instant |
| 2 | WebRTC DataChannel | Cross-network P2P / TURN relay | ~50-100ms | 2-5s |

All transports carry identical JSON message protocol. Upper-layer code (sessions, terminal, auth) is transport-agnostic.

## Part 1: LAN WebSocket

### LAN IP Discovery

The kite daemon detects its LAN IP at startup and advertises it via the signaling join message:

```json
{
  "type": "join",
  "pairing_code": "abc123",
  "role": "daemon",
  "lan_ip": "192.168.1.100",
  "lan_port": 7890
}
```

The signal server forwards this as-is (no changes needed — it already relays arbitrary JSON fields in `member_joined`).

The frontend receives `lan_ip` + `lan_port` from the `member_joined` or `joined` message and attempts `ws://<lan_ip>:<lan_port>/ws`.

### Backend Implementation

Reuse the existing HTTP server in `http.zig`:

- Add `/ws` route that performs WebSocket upgrade
- Reuse `ws.zig` frame parsing (already implements RFC 6455)
- Authenticated WS clients join the same broadcast list as RTC peers
- Heart beat via WebSocket ping/pong frames

### Authentication

Same flow as DataChannel:

1. WS connects → client sends `{ "type": "auth", "token": "..." }`
2. Server validates token → responds with `{ "type": "auth_result", "success": true }`
3. Authenticated clients receive broadcasts (sessions_sync, terminal_output, etc.)

### Message Protocol

Identical to DataChannel — same JSON message types, same base64-encoded terminal output, same chunking for large payloads. No protocol changes needed.

## Part 2: Transport Manager (Frontend)

### Interface

```typescript
interface Transport {
  readonly name: string;
  readonly priority: number;       // lower = higher priority
  connect(params: ConnectParams): Promise<void>;
  send(data: string): void;
  isOpen(): boolean;
  onMessage(handler: (msg: ServerMessage) => void): () => void;
  onStateChange(handler: (open: boolean) => void): () => void;
  disconnect(): void;
}
```

### TransportManager

```typescript
class TransportManager {
  private transports: Transport[] = [];  // sorted by priority

  send(msg: object): void;               // sends via best available transport
  onMessage(handler): () => void;         // unified message stream
  isConnected(): boolean;                 // any transport open?
  activeTransport(): string | null;       // name of current transport
  disconnect(): void;                     // disconnect all
}
```

### Channel Selection Logic

- All transports connect in parallel on startup
- `send()` picks the highest-priority transport where `isOpen() === true`
- When a higher-priority transport opens → automatic upgrade, trigger `request_sync`
- When current transport closes → automatic downgrade to next available
- No simultaneous sending on multiple transports (avoids duplication/reordering)

### Transport Implementations

- `LanWebSocket` implements `Transport` (priority 1) — new
- `WebRtcTransport` implements `Transport` (priority 2) — refactored from existing `RtcManager`

`RtcManager` keeps its WebRTC-specific logic (SDP negotiation, ICE restart, recovery) but exposes the `Transport` interface to `TransportManager`.

### Recovery on visibilitychange

When the page becomes visible:

1. `TransportManager` triggers recovery on all transports
2. LAN WS: simple reconnect (TCP)
3. WebRTC: existing ICE restart / DC probe logic (unchanged)
4. First transport to recover wins → `request_sync`

## Part 3: ICE Server Configuration

### Current Problems

- Backend: 4 STUN servers hardcoded in `rtc.zig`, only 1 optional TURN via CLI
- Frontend: 1 STUN server hardcoded, no TURN support
- Front/back STUN lists inconsistent
- No persistence of TURN configuration

### Solution: Backend-Managed ICE Servers

**Single source of truth**: Backend manages the full ICE server list and delivers it to the frontend via signaling.

#### Backend Config

```zig
const default_ice_servers = [_][]const u8{
    "stun:stun.qq.com:3478",
    "stun:stun.miwifi.com:3478",
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
};
```

#### CLI

```bash
# Append ICE servers (merged with defaults)
kite start --ice-server "turn:user:pass@turn.example.com:3478"

# Multiple servers
kite start --ice-server "stun:custom.com:3478" \
           --ice-server "turn:user:pass@relay.com:3478"
```

Replaces the current `--turn-server` flag.

#### Persistence

`~/.config/kite/config.json`:

```json
{
  "signal_url": "wss://kite.fun.dev/remote",
  "pairing_code": "abc123",
  "setup_secret": "...",
  "ice_servers": [
    "turn:user:pass@turn.example.com:3478"
  ]
}
```

Config file `ice_servers` merge with default list. CLI `--ice-server` flags also merge. Duplicates are removed.

#### Delivery to Frontend

Daemon includes ICE servers in signaling join metadata:

```json
{
  "type": "member_joined",
  "member_id": "xxx",
  "role": "daemon",
  "lan_ip": "192.168.1.100",
  "lan_port": 7890,
  "ice_servers": [
    "stun:stun.qq.com:3478",
    "stun:stun.miwifi.com:3478",
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
    "turn:user:pass@turn.example.com:3478"
  ]
}
```

Frontend parses these into `RTCIceServer[]` format. No hardcoded servers in frontend code.

#### Signal Server Changes

None. The signal server relays JSON payloads opaquely — additional fields in join/member_joined are forwarded as-is.

## Part 4: Backend Broadcast Unification

Currently only RTC peers receive broadcast messages. With LAN WebSocket added, the broadcast system needs to handle both types of clients.

### Unified Client Registry

```zig
const ClientType = enum { rtc, websocket };

const Client = struct {
    client_type: ClientType,
    member_id: []const u8,
    authenticated: bool = false,
    // Union of transport-specific handles
    rtc_peer: ?*RtcPeer = null,
    ws_conn: ?*WsConn = null,
};
```

`broadcastViaRtc()` becomes `broadcastToClients()` — iterates all authenticated clients regardless of transport type.

### Deduplication

A single browser may have both LAN WS and WebRTC active simultaneously. The backend broadcasts to all authenticated clients regardless of transport type. The frontend `TransportManager` handles deduplication: only the active (highest-priority open) transport's messages are forwarded to the application layer. Messages arriving on non-active transports are silently discarded.

This keeps the backend simple — no need to track which transports belong to the same browser or manage transport-level routing.

## Implementation Phases

### Phase 1: LAN WebSocket + Transport Framework

1. Backend: LAN IP detection, `/ws` WebSocket endpoint, unified broadcast
2. Frontend: `Transport` interface, `LanWebSocket` implementation, `TransportManager`
3. Frontend: Refactor `RtcManager` → `WebRtcTransport` implementing `Transport`
4. Frontend: Wire `TransportManager` into `App.svelte` replacing direct `RtcManager` usage

### Phase 2: ICE Server Configuration

5. Backend: Replace hardcoded STUN + single TURN with `ice_servers` list
6. Backend: `--ice-server` CLI flag, config.json persistence, merge logic
7. Backend: Include `ice_servers` in signaling join metadata
8. Frontend: Read ICE servers from signaling, remove hardcoded STUN

### Future: WebTransport (QUIC)

- Go sidecar using `webtransport-go`, communicating with kite via Unix socket
- New `WebTransportChannel` implementing `Transport` interface (priority between LAN WS and WebRTC)
- Requires: Let's Encrypt certificate for `kite.fun.dev`, Chrome mobile
