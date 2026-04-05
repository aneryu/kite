# Open Source Preparation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the Kite repository for public release on GitHub with all standard open-source files.

**Architecture:** No code changes — only adding documentation files, GitHub templates, and cleaning up gitignore. The signal server's `go.mod` module path references `github.com/anthropics/kite/signal` which should be updated to `github.com/aneryu/kite/signal`.

**Tech Stack:** Markdown, YAML (GitHub issue templates)

**Spec:** `docs/superpowers/specs/2026-04-06-open-source-prep-design.md`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `LICENSE` | MIT license |
| Create | `README.md` | Full project README |
| Create | `CONTRIBUTING.md` | Contribution guide |
| Create | `.github/ISSUE_TEMPLATE/bug_report.md` | Bug report template |
| Create | `.github/ISSUE_TEMPLATE/feature_request.md` | Feature request template |
| Create | `.github/PULL_REQUEST_TEMPLATE.md` | PR template |
| Modify | `.gitignore` | Add OS/editor/signal ignores |
| Modify | `signal/go.mod` | Update module path to `github.com/aneryu/kite/signal` |
| Modify | `signal/cmd/signal/main.go` | Update import path |

---

### Task 1: LICENSE

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: Create MIT license file**

```
MIT License

Copyright (c) 2026 Yuzhe Chen

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "chore: add MIT license"
```

---

### Task 2: .gitignore cleanup

**Files:**
- Modify: `.gitignore`

Current contents of `.gitignore`:
```
.zig-cache
zig-out
web/node_modules/
web/dist/
```

- [ ] **Step 1: Append OS, editor, and signal ignores**

Add the following lines after the existing content:

```
# OS
.DS_Store
Thumbs.db

# Editor
*.swp
*.swo
.vscode/
.idea/

# Signal server binary
signal/signal
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: extend gitignore with OS, editor, and signal binary patterns"
```

---

### Task 3: Update signal server module path

The signal server's `go.mod` currently uses `github.com/anthropics/kite/signal`. Update it to match the new GitHub owner.

**Files:**
- Modify: `signal/go.mod` — change module path
- Modify: `signal/cmd/signal/main.go` — update import path

- [ ] **Step 1: Update go.mod module path**

In `signal/go.mod`, change line 1:

Old: `module github.com/anthropics/kite/signal`
New: `module github.com/aneryu/kite/signal`

- [ ] **Step 2: Update import in cmd/signal/main.go**

In `signal/cmd/signal/main.go`, change the import:

Old: `"github.com/anthropics/kite/signal"`
New: `"github.com/aneryu/kite/signal"`

- [ ] **Step 3: Verify signal server builds**

```bash
cd signal && go build ./cmd/signal/
```

Expected: builds successfully with no errors.

- [ ] **Step 4: Commit**

```bash
git add signal/go.mod signal/cmd/signal/main.go
git commit -m "chore: update signal server module path to github.com/aneryu/kite"
```

---

### Task 4: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create README.md**

Write the full README with the following content. Key details derived from the codebase:

- Project name: **Kite**
- Commands: `kite start [--cmd claude] [--signal-url ws://...] [--stun-server ...]`, `kite setup`, `kite hook --event <name>`, `kite status`
- Prerequisites: Zig 0.15.2+, libdatachannel, Node.js (for web build), Go 1.16+ (for signal server)
- Build: `zig build` produces `zig-out/bin/kite`
- Signal server: `cd signal && go run ./cmd/signal/ [--port 8080]`
- Web frontend: `cd web && npm install && npm run build`
- Tests: `zig build test` (Zig), `cd signal && go test ./...` (Go)

```markdown
# Kite

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange.svg)](https://ziglang.org/)

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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add comprehensive README"
```

---

### Task 5: CONTRIBUTING.md

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Create CONTRIBUTING.md**

```markdown
# Contributing to Kite

Thank you for your interest in contributing to Kite! This guide will help you get started.

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork:
   ```bash
   git clone --recursive https://github.com/<your-username>/kite.git
   cd kite
   ```
3. Install prerequisites:
   - [Zig](https://ziglang.org/download/) 0.15.2 or later
   - [libdatachannel](https://github.com/paullouisageneau/libdatachannel) (for WebRTC)
   - [Node.js](https://nodejs.org/) (for the web frontend)
   - [Go](https://golang.org/) 1.16+ (for the signal server)

4. Verify everything builds:
   ```bash
   zig build test
   cd web && npm install && npm run build && cd ..
   cd signal && go test ./... && cd ..
   ```

## Project Structure

```
kite/
├── src/              # Zig backend — PTY proxy, auth, hooks, WebRTC, protocol
├── web/              # Svelte 5 + TypeScript — mobile terminal UI
├── signal/           # Go — WebRTC signaling server
├── libdatachannel/   # Git submodule — WebRTC C library
└── docs/             # Documentation
```

## Development Workflow

1. Create a feature branch from `main`:
   ```bash
   git checkout -b feat/your-feature main
   ```

2. Make your changes and write tests where applicable

3. Run the relevant test suites:
   ```bash
   zig build test                    # Zig backend
   cd signal && go test ./...        # Signal server
   ```

4. Commit using [Conventional Commits](https://www.conventionalcommits.org/):
   ```
   feat: add new feature
   fix: resolve specific bug
   docs: update documentation
   refactor: restructure without behavior change
   test: add or update tests
   chore: maintenance tasks
   ```

5. Push to your fork and submit a Pull Request

## Code Style

### Zig (Backend)

- Zig 0.15.2 API conventions: `std.fs.File.stdout()`, `.writer(&buf)`, `.interface`
- ArrayList: `.empty` init, allocator passed to methods (`.append(alloc, v)`)
- Link libc for PTY operations
- Manual JSON construction via `std.fmt.allocPrint`

### Svelte / TypeScript (Web Frontend)

- Svelte 5 with TypeScript
- Components in `web/src/lib/`

### Go (Signal Server)

- Standard Go conventions
- `go fmt` and `go vet` before committing

## Reporting Bugs

Please use the [Bug Report](https://github.com/aneryu/kite/issues/new?template=bug_report.md) issue template. Include:

- Steps to reproduce
- Expected vs. actual behavior
- Your environment (OS, Zig version, browser)

## Requesting Features

Please use the [Feature Request](https://github.com/aneryu/kite/issues/new?template=feature_request.md) issue template. Describe:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Questions?

Open a [discussion](https://github.com/aneryu/kite/discussions) or file an issue — we're happy to help.
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add contributing guide"
```

---

### Task 6: GitHub Templates

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/feature_request.md`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

- [ ] **Step 1: Create bug report template**

`.github/ISSUE_TEMPLATE/bug_report.md`:

```markdown
---
name: Bug Report
about: Report a bug to help us improve
title: ''
labels: bug
assignees: ''
---

## Description

A clear and concise description of the bug.

## Steps to Reproduce

1. ...
2. ...
3. ...

## Expected Behavior

What you expected to happen.

## Actual Behavior

What actually happened.

## Environment

- **OS:** (e.g., macOS 15, Ubuntu 24.04)
- **Zig version:** (e.g., 0.15.2)
- **Browser:** (e.g., Safari on iOS 18, Chrome on Android 15)
- **Kite version/commit:** (e.g., v0.1.0 or commit hash)

## Additional Context

Any other context, logs, or screenshots.
```

- [ ] **Step 2: Create feature request template**

`.github/ISSUE_TEMPLATE/feature_request.md`:

```markdown
---
name: Feature Request
about: Suggest an idea for Kite
title: ''
labels: enhancement
assignees: ''
---

## Problem

A clear description of the problem you're trying to solve.

## Proposed Solution

Describe the solution you'd like.

## Alternatives Considered

Any alternative solutions or features you've considered.

## Additional Context

Any other context or screenshots about the feature request.
```

- [ ] **Step 3: Create PR template**

`.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## Description

What does this PR do?

## Related Issue

Fixes #(issue number)

## How to Test

Steps to test the changes:

1. ...
2. ...

## Checklist

- [ ] Tests pass (`zig build test`, `go test ./...`)
- [ ] Code follows project conventions
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] Documentation updated (if applicable)
```

- [ ] **Step 4: Commit**

```bash
git add .github/
git commit -m "chore: add GitHub issue and PR templates"
```

---

### Task 7: Final verification

- [ ] **Step 1: Verify all new files exist**

```bash
ls -la LICENSE README.md CONTRIBUTING.md
ls -la .github/ISSUE_TEMPLATE/bug_report.md .github/ISSUE_TEMPLATE/feature_request.md .github/PULL_REQUEST_TEMPLATE.md
```

Expected: all 6 files present.

- [ ] **Step 2: Verify build still works**

```bash
zig build
```

Expected: builds successfully.

- [ ] **Step 3: Review git log**

```bash
git log --oneline -10
```

Expected: new commits for LICENSE, gitignore, signal module path, README, CONTRIBUTING, and GitHub templates.
