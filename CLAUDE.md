# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Kite is a remote controller for AI coding assistants (Claude Code, etc.). It proxies CLI tools through a PTY, listens to Claude Code hooks, and exposes a WebSocket + HTTP server for remote control from a phone browser.

## Build, Test & Run

| Command | Description |
|---|---|
| `zig build` | Build (output: `zig-out/bin/kite`) |
| `zig build run -- start` | Build and run the server |
| `zig build test` | Run all unit tests |

Runtime commands: `kite start [--port 7890] [--bind 0.0.0.0] [--cmd claude]`, `kite hook --event <name>`, `kite setup`, `kite status`.

## Architecture

**Data flow:** Claude Code → hook events via Unix socket (`/tmp/kite.sock`) → kite IPC listener → WsBroadcaster → WebSocket → phone browser. Phone input flows back: browser → WebSocket → HTTP callbacks → PTY master → child process.

Key components:
- **PTY Proxy** (`pty.zig`): C interop (`openpty`) + `posix.fork()` to spawn and relay I/O to child processes
- **Session** (`session.zig`): 64KB ring buffer for terminal output history, session state machine (starting/running/waiting_approval/stopped)
- **HTTP/WS** (`http.zig`, `ws.zig`): `std.http.Server` with WebSocket upgrade, thread-safe client broadcaster
- **Auth** (`auth.zig`): Random 32-byte tokens, hex-encoded. Single-use setup token (5min TTL) exchanges for session token
- **Hooks** (`hooks.zig`): IPC via Unix domain socket, receives Claude Code hook events (SessionStart, PreToolUse, PostToolUse, Notification, Stop)
- **Protocol** (`protocol.zig`): JSON message encoding/decoding, base64 for terminal output
- **Web UI** (`web.zig`): Single-page mobile app embedded as comptime string literal, built on xterm.js
- **Main** (`main.zig`): CLI parsing, event loop polling PTY master + stdin, spawns HTTP and IPC threads

## Debug Logging

设置 `KITE_DEBUG=1` 环境变量启用调试日志。日志同时输出到 stderr 和 `/tmp/kite.log`。未设置该变量时无任何日志输出。

统一日志模块为 `log.zig`，各模块通过 `log.debug(fmt, args)` 输出日志。

## Zig Conventions (0.15.2)

- `std.fs.File.stdout()`, `.writer(&buf)`, `.interface` field/method
- ArrayList: `.empty` init, allocator passed to methods (`.append(alloc, v)`)
- POSIX socket APIs take `u32` flags: `posix.SOCK.STREAM | posix.SOCK.CLOEXEC`
- `std.Thread.sleep()` (not `std.time.sleep()`)
- Link libc for PTY operations (`openpty`, `ioctl`, `TIOCSCTTY`)
- Manual JSON construction via `std.fmt.allocPrint` (not `json.stringifyAlloc`)
