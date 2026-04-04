# Repository Guidelines

## Project Overview

Kite is a remote controller for AI coding assistants (Claude Code, etc.). It proxies CLI tools through a PTY, listens to hooks, and exposes a WebSocket + HTTP server for remote control from a phone browser.

## Project Structure

```
kite/
├── build.zig          # Build configuration
├── build.zig.zon      # Package manifest (Zig 0.15.2+)
└── src/
    ├── main.zig       # CLI entry point (start, hook, setup, status)
    ├── root.zig       # Library module (re-exports all public APIs)
    ├── pty.zig        # PTY pair creation, fork/exec, I/O relay
    ├── session.zig    # Ring buffer (64KB), session state machine
    ├── http.zig       # HTTP server using std.net/std.http.Server
    ├── ws.zig         # WebSocket broadcaster, client management
    ├── auth.zig       # Ed25519 auth, setup token, session JWT
    ├── hooks.zig      # Claude Code hooks integration, IPC via Unix socket
    ├── protocol.zig   # JSON message encoding/decoding for WS
    └── web.zig        # Embedded HTML/JS/CSS mobile Web UI
```

## Build, Test & Run Commands

| Command | Description |
|---|---|
| `zig build` | Build the project (output: `zig-out/bin/kite`) |
| `zig build run -- start` | Build and run the server |
| `zig build test` | Run all unit tests |
| `kite start [--port 7890] [--bind 0.0.0.0] [--cmd claude]` | Start server |
| `kite hook --event <name>` | Handle Claude Code hook (internal) |
| `kite setup` | Print Claude Code hooks configuration |
| `kite status` | Check if kite server is running |

## Coding Style & Conventions

- Zig 0.15.2 API: `std.fs.File.stdout()`, `.writer(&buf)`, `.interface` field/method
- ArrayList uses `.empty` init, allocator passed to methods: `.append(alloc, v)`
- POSIX socket APIs take `u32` flags: `posix.SOCK.STREAM | posix.SOCK.CLOEXEC`
- `std.Thread.sleep()` instead of `std.time.sleep()`
- Link libc for PTY operations (`openpty`, `ioctl`, `TIOCSCTTY`)
- Manual JSON construction via `std.fmt.allocPrint` (not `json.stringifyAlloc`)

## Architecture Notes

- **PTY Proxy**: Uses C interop (`openpty` from `<util.h>`) + Zig `posix.fork()`
- **IPC**: Unix domain socket at `/tmp/kite.sock` for hook communication
- **HTTP/WS**: `std.net.Address.listen()` + `std.http.Server` with built-in WebSocket
- **Auth**: Random 32-byte tokens, hex-encoded. Setup token -> session token exchange
- **Web UI**: Single HTML file embedded as comptime string literal in `web.zig`
