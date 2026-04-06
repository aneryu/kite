# CLI UX Improvements Design Spec

## Overview

Improve the Kite CLI user experience across four areas: help output, error messages, pre-built binary releases, and Homebrew distribution.

**Implementation order:** A (CLI first) — Help + error improvements first (pure Zig, immediately testable), then CI/CD + Homebrew.

## Scope

| Area | In Scope | Out of Scope |
|------|----------|--------------|
| Help output | Cobra-style per-command help, examples, color | Shell completion, man pages |
| Error messages | Fuzzy "did you mean", missing arg hints | Structured error codes |
| Pre-built binaries | macOS + Linux, arm64 + x86_64, static linking | Windows, installer packages |
| Homebrew | Tap formula, binary download | Core formula, auto-update CI |
| Version | Not included this round | `kite version` command |

---

## Part 1: Help Output — Cobra Style

### Current State

All help is in a single `printUsage()` function. Subcommands have no independent `--help`. Output is plain text with no formatting.

### Design

**Root help** (`kite` or `kite help`):

```
kite - AI coding assistant remote controller

Usage:
  kite <command> [options]

Commands:
  start    Start the kite daemon
  run      Create a new session in the daemon
  setup    Configure kite and show Claude Code hooks config
  status   Check daemon status and show pairing info
  hook     Handle Claude Code hook events (internal)

Run 'kite <command> --help' for more information on a command.
```

**Subcommand help** (`kite start --help`):

```
Start the kite daemon and connect to the signal server.

Usage:
  kite start [options]

Options:
  --no-auth              Disable authentication (development only)
  --signal-url <URL>     Signal server URL (overrides config file)

Examples:
  kite start                         Start with default settings
  kite start --signal-url wss://my.server.com
```

Each subcommand follows the same pattern: description, usage, options, examples.

### Implementation

- Replace `printUsage()` with `printRootHelp()` (command overview + footer).
- Add `printStartHelp()`, `printRunHelp()`, `printSetupHelp()`, `printStatusHelp()`, `printHookHelp()`.
- Each `runXxx()` function checks for `--help`/`-h` in args and calls its help function before doing any work.
- **Color output**: Use ANSI escape codes. Detect terminal via `std.posix.isatty()` on stdout fd. Non-terminal output falls back to plain text. Color scheme: command names green, options yellow, section headers bold.
- All help functions write to a buffered stdout writer for consistency.

### Files Modified

| File | Change |
|------|--------|
| `src/main.zig` | Replace `printUsage()`, add per-command help functions, add `--help` detection in each `runXxx()` |

---

## Part 2: Error Messages

### Current State

Unknown commands print the full help text. Unknown options are silently ignored or cause unclear errors. Missing required args produce no specific message.

### Design

**Unknown command with suggestion:**
```
Unknown command: 'star'. Did you mean 'start'?

Run 'kite help' for a list of commands.
```

**Unknown option with suggestion:**
```
Unknown option: '--no-auht'. Did you mean '--no-auth'?

Run 'kite start --help' for usage.
```

**Missing required option:**
```
Missing required option: --event <name>

Usage:
  kite hook --event <name>
```

### Implementation

- **Levenshtein distance**: Implement a small function (~30 lines) that computes edit distance between two strings. Threshold ≤ 2 triggers a "Did you mean..." suggestion.
- **Command matching**: After `StaticStringMap` lookup fails, iterate known commands and find the closest match.
- **Option matching**: In each `runXxx()` argument loop, when an arg starts with `--` and doesn't match any known option, find the closest known option for that subcommand.
- **Required arg check**: At the top of `runHook()`, check that `--event` was provided. Pattern applies to any future required args.
- Error output goes to stderr.

### Files Modified

| File | Change |
|------|--------|
| `src/main.zig` | Add `levenshteinDistance()`, update command dispatch to suggest on miss, update arg parsing in each `runXxx()` to detect unknown options |

---

## Part 3: Pre-built Binary Releases

### Goal

Push a git tag → GitHub Actions builds 4 binaries → uploads to GitHub Releases.

### Target Platforms

| OS | Arch | Runner | Notes |
|----|------|--------|-------|
| macOS | arm64 | `macos-14` | Native Apple Silicon |
| macOS | x86_64 | `macos-13` | Native Intel |
| Linux | x86_64 | `ubuntu-24.04` | Native |
| Linux | arm64 | `ubuntu-24.04` | Zig cross-compilation (`-Dtarget=aarch64-linux-gnu`) |

### CI Pipeline

**Trigger:** `on: push: tags: ['v*']`

**Per-platform job steps:**
1. Checkout repo (with submodules)
2. Install Zig 0.15.2 (via `mlugg/setup-zig@v2` or similar)
3. Install Node.js, build web UI (`cd web && npm ci && npm run build`)
4. Install/build libdatachannel static library
   - macOS: `brew install libdatachannel` (use static .a from Homebrew)
   - Linux: Build from source with CMake (`-DBUILD_SHARED_LIBS=OFF`)
5. `zig build -Doptimize=ReleaseSafe` (with appropriate link flags for static lib)
6. Package: `tar czf kite-{os}-{arch}.tar.gz kite`
7. Upload artifact

**Release job** (depends on all 4 build jobs):
- Create GitHub Release from tag
- Upload all 4 tar.gz files

### build.zig Changes

Current `build.zig` hardcodes `/opt/homebrew/lib` for libdatachannel. Need to:
- Add build option for library search path: `-Dlibdatachannel-path=<path>`
- Support static linking via `-Dstatic=true` flag
- Default behavior unchanged for local development

### Artifact Naming

```
kite-darwin-arm64.tar.gz
kite-darwin-amd64.tar.gz
kite-linux-amd64.tar.gz
kite-linux-arm64.tar.gz
```

### Files Created/Modified

| File | Change |
|------|--------|
| `.github/workflows/release.yml` | New: CI workflow |
| `build.zig` | Add `-Dlibdatachannel-path`, `-Dstatic` options |

---

## Part 4: Homebrew Formula

### Install Experience

```bash
brew tap aneryu/kite
brew install kite
```

### Formula Design

- Lives in separate repo: `aneryu/homebrew-kite`
- Downloads pre-built binary from GitHub Releases (no source compilation)
- Platform detection via `on_macos`/`on_linux` + `on_arm`/`on_intel` blocks
- `def install` simply copies binary to `bin/`

### Formula Structure

```ruby
class Kite < Formula
  desc "Remote controller for AI coding assistants"
  homepage "https://github.com/aneryu/kite"
  version "0.1.0"

  on_macos do
    on_arm do
      url "https://github.com/aneryu/kite/releases/download/v0.1.0/kite-darwin-arm64.tar.gz"
      sha256 "..."
    end
    on_intel do
      url "https://github.com/aneryu/kite/releases/download/v0.1.0/kite-darwin-amd64.tar.gz"
      sha256 "..."
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/aneryu/kite/releases/download/v0.1.0/kite-linux-arm64.tar.gz"
      sha256 "..."
    end
    on_intel do
      url "https://github.com/aneryu/kite/releases/download/v0.1.0/kite-linux-amd64.tar.gz"
      sha256 "..."
    end
  end

  def install
    bin.install "kite"
  end

  test do
    assert_match "kite", shell_output("#{bin}/kite help")
  end
end
```

### Update Process

Initial: manual update of version + sha256 after each release.
Future: can automate via CI step that pushes to homebrew-kite repo after release.

### Files Created

| File | Location | Notes |
|------|----------|-------|
| `Formula/kite.rb` | `aneryu/homebrew-kite` repo | New repo needed |

---

## Implementation Phases

### Phase 1: CLI Improvements (this repo, pure Zig)
1. Refactor help output to cobra style with per-command help
2. Add Levenshtein distance and error suggestions
3. Add color output with terminal detection

### Phase 2: CI/CD (this repo, GitHub Actions)
4. Update `build.zig` for configurable library paths and static linking
5. Create `.github/workflows/release.yml`
6. Test builds on all 4 platforms

### Phase 3: Homebrew (separate repo)
7. Create `aneryu/homebrew-kite` repo with formula
8. Test `brew tap` + `brew install` flow

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Help style | Cobra/gh style | Industry standard, users already familiar |
| Fuzzy match threshold | Levenshtein ≤ 2 | Catches typos without false positives |
| Static linking | Yes for releases | Zero runtime dependencies for end users |
| Linux arm64 | Cross-compile | Cheaper than native arm64 runner |
| Homebrew | Tap (not core) | Faster to ship, no review process |
| Formula update | Manual initially | Automate later when release flow is stable |
