# Kite

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)
<!-- [![Build Status](https://github.com/aneryu/kite/actions/workflows/ci.yml/badge.svg)](https://github.com/aneryu/kite/actions) -->

> Remote controller for AI coding assistants from your phone.

Kite lets you monitor and control [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (and other CLI-based AI coding assistants) from your phone's browser. It wraps the CLI in a PTY proxy, captures hook events, and streams everything over WebRTC to a mobile-friendly terminal UI.

## Demo

<!-- TODO: Add screenshot or GIF demo here -->
<!-- ![Kite Demo](docs/demo.gif) -->

## Features

- **Phone Remote Control** — Monitor and interact with Claude Code from your phone browser
- **Full Terminal Experience** — PTY proxy preserves colors, cursor movement, and all terminal capabilities
- **WebRTC P2P** — Real-time, low-latency communication directly between your computer and phone
- **Mobile Terminal UI** — xterm.js-based interface optimized for mobile screens
- **Claude Code Hooks** — Intercepts hook events (approval requests, notifications, session lifecycle)
- **Secure Authentication** — Pairing code + session token exchange, no passwords stored

## Architecture

```
┌──────────────┐    hooks     ┌──────────────┐   WebRTC    ┌──────────────┐
│  Claude Code │ ──────────── │     Kite     │ ◄─────────► │    Phone     │
│   (or any    │  Unix socket │  PTY Proxy   │ DataChannel │   Browser    │
│    CLI AI)   │              │              │             │  (xterm.js)  │
└──────────────┘              └──────┬───────┘             └──────────────┘
                                     │
                                     │ WebSocket
                                     ▼
                              ┌──────────────┐
                              │   Signal     │
                              │   Server     │
                              └──────────────┘
```

**Key Components:**

| Component | Description |
|-----------|-------------|
| **PTY Proxy** (`src/pty.zig`) | Spawns child process in a pseudo-terminal, relays I/O |
| **Session Manager** (`src/session_manager.zig`) | Tracks multiple sessions with 64KB ring buffers |
| **Auth** (`src/auth.zig`) | Pairing code generation, session token exchange |
| **Hooks** (`src/hooks.zig`) | Receives Claude Code hook events via Unix socket (`/tmp/kite.sock`) |
| **WebRTC** (`src/rtc.zig`) | Peer connection management via libdatachannel |
| **Signal Client** (`src/signal_client.zig`) | Connects to signaling server for WebRTC negotiation |
| **Web UI** (`web/`) | Svelte 5 mobile app with xterm.js terminal |
| **Signal Server** (`signal/`) | Go WebSocket server for WebRTC signaling |

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.2 or later
- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) (for WebRTC)
- [Node.js](https://nodejs.org/) (for building the web UI)
- [Go](https://golang.org/) 1.16+ (for the signal server)

### Install & Run

```bash
# Clone the repository
git clone --recursive https://github.com/aneryu/kite.git
cd kite

# Build the web UI
cd web && npm install && npm run build && cd ..

# Build kite
zig build

# Start the signal server (in a separate terminal)
cd signal && go run ./cmd/signal/

# Run kite
zig build run -- start
```

Open the pairing URL shown in the terminal on your phone's browser.

## Usage

### `kite start`

Start kite, spawning the AI coding assistant in a PTY proxy.

```bash
kite start [options]
```

| Option | Default | Description |
|--------|---------|-------------|
| `--cmd` | `claude` | Command to run in the PTY |
| `--signal-url` | `ws://localhost:8080` | Signal server WebSocket URL |
| `--stun-server` | `stun:stun.l.google.com:19302` | STUN server for WebRTC |
| `--turn-server` | *(none)* | TURN server for WebRTC relay |
| `--no-auth` | `false` | Disable authentication |

### `kite setup`

Print the Claude Code hooks configuration for integrating with kite.

```bash
kite setup
```

### `kite hook`

Handle a Claude Code hook event (called by Claude Code, not directly by users).

```bash
kite hook --event <event_name>
```

### `kite status`

Check if kite is currently running.

```bash
kite status
```

## Signal Server

The signal server (`signal/`) is a lightweight Go WebSocket server that facilitates WebRTC peer connection negotiation between kite and the phone browser.

```bash
cd signal
go run ./cmd/signal/ [--port 8080] [--static <dir>]
```

For production deployment, build the binary:

```bash
cd signal
go build -o signal ./cmd/signal/
./signal --port 8080
```

## Development

### Zig Backend

```bash
zig build          # Build
zig build test     # Run tests
zig build run -- start  # Build and run
```

### Web Frontend

```bash
cd web
npm install
npm run dev        # Dev server with hot reload
npm run build      # Production build
```

### Signal Server

```bash
cd signal
go test ./...              # Run tests
go run ./cmd/signal/       # Run locally
```

## Roadmap

- [ ] Multi-session support in the web UI
- [ ] Support for more AI coding assistants beyond Claude Code
- [ ] TURN server integration for NAT traversal
- [ ] Desktop companion app

## FAQ

**Q: Does kite work with AI assistants other than Claude Code?**
A: Yes — `kite start --cmd <command>` can wrap any CLI tool in a PTY. However, the hooks integration is currently specific to Claude Code.

**Q: Do my computer and phone need to be on the same network?**
A: Not necessarily. WebRTC uses STUN to establish P2P connections across NATs. If direct connection fails, you can configure a TURN server as a relay with `--turn-server`.

**Q: Is the connection between my computer and phone secure?**
A: Yes. WebRTC DataChannels are encrypted with DTLS. Additionally, kite uses a pairing code + session token for authentication.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
