# Open Source Preparation — Design Spec

**Date:** 2026-04-06
**Repository:** github.com/aneryu/kite
**License:** MIT (Copyright Yuzhe Chen)

## Overview

Prepare the Kite project for public release on GitHub. This includes adding standard open-source files (license, readme, contributing guide, templates), cleaning up gitignore, and removing tracked artifacts.

## Files to Create

### 1. LICENSE

MIT license, copyright holder: Yuzhe Chen, year: 2026.

### 2. README.md

Full README in English with the following sections:

1. **Header** — Project name, badges (license, zig version, build status)
2. **Introduction** — One-liner: "Remote controller for AI coding assistants from your phone"
3. **Demo** — Screenshot/GIF placeholder with HTML comment
4. **Features** — Bullet list:
   - Phone remote control for Claude Code and other AI coding assistants
   - PTY proxy with full terminal experience
   - WebRTC real-time communication (P2P, low latency)
   - xterm.js mobile terminal UI
   - Claude Code hooks integration (approval, notifications, etc.)
   - Secure authentication (pairing code + session token)
5. **Architecture** — Text-based data flow diagram:
   `Claude Code → hooks → kite (PTY proxy) → WebRTC DataChannel → phone browser`
   Brief description of key components: PTY, session, auth, hooks, WebRTC, signal server
6. **Quick Start** — Prerequisites (Zig 0.15.2+, Node.js, Go), build, run
7. **Usage** — Detailed command reference: `kite start`, `kite setup`, `kite hook`, `kite status`
8. **Signal Server** — What it does, how to run it, deployment notes
9. **Development** — Local dev setup for each component (zig build, web dev, signal server)
10. **Roadmap** — Placeholder bullet points for future direction
11. **FAQ** — 2-3 basic Q&A entries (placeholder)
12. **Contributing** — Link to CONTRIBUTING.md
13. **License** — MIT, link to LICENSE file

### 3. CONTRIBUTING.md

English, covering:

1. **Getting Started** — Fork, clone, prerequisites (Zig 0.15.2+, Node.js, Go)
2. **Project Structure** — Three components: `src/` (Zig backend), `web/` (Svelte 5 frontend), `signal/` (Go signaling server)
3. **Development Workflow** — Feature branch, code + test, conventional commits, submit PR
4. **Code Style** — Zig conventions per CLAUDE.md, Svelte 5 + TypeScript for web, standard Go for signal
5. **Reporting Bugs** — Link to bug report issue template
6. **Requesting Features** — Link to feature request issue template

### 4. .github/ISSUE_TEMPLATE/bug_report.md

Standard GitHub issue template with YAML frontmatter:
- Description
- Steps to reproduce
- Expected behavior
- Actual behavior
- Environment (OS, Zig version, browser)

### 5. .github/ISSUE_TEMPLATE/feature_request.md

Standard GitHub issue template:
- Problem description
- Proposed solution
- Alternatives considered

### 6. .github/PULL_REQUEST_TEMPLATE.md

Standard PR template:
- Description of changes
- Related issue
- How to test
- Checklist (tests pass, docs updated, conventional commit message)

## Files to Modify

### 7. .gitignore

Append to existing file:

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

## Cleanup Actions

### 8. Remove tracked .DS_Store

```bash
git rm --cached .DS_Store
```

## Sensitive Information Audit

A full scan of the codebase was performed. **No sensitive information found:**
- Localhost URLs are appropriate defaults
- Google STUN server is a public service
- `/tmp/` paths are standard
- No API keys, passwords, personal data, or secrets in source code

## Out of Scope

- CI/CD pipeline setup (GitHub Actions)
- Publishing to package registries
- Setting up GitHub repository settings (branch protection, etc.)
- Creating demo screenshots/GIFs (placeholder only)
