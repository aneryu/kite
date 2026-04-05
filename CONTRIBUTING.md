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
