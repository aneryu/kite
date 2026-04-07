# Frontend Visual Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Full visual refresh of the Kite web frontend — terminal detail page redesign, SessionCard polish, global consistency fixes, and Nerd Font loading for Powerline symbol support.

**Architecture:** Pure frontend changes across Svelte components and CSS. No backend/protocol changes. Font loaded as self-hosted TTF via `@font-face`. Font size preference stored in `localStorage`. All changes built with `cd web && npm run build` which outputs to `signal/static/`.

**Tech Stack:** Svelte 5, TypeScript, xterm.js, Vite, CSS custom properties

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `web/public/fonts/HackNerdFontMono-Regular.ttf` | Create | Self-hosted Nerd Font file |
| `web/src/app.css` | Modify | `@font-face`, body tweaks, `--nav-height`, `will-change` |
| `web/src/components/TerminalView.svelte` | Modify | Accept `fontSize` prop, update fontFamily, default 11px |
| `web/src/components/SessionDetail.svelte` | Modify | Remove PromptOverlay + status badge, add ConnectionStatus + font controls + Enter button + glow line |
| `web/src/components/SessionCard.svelte` | Modify | Card shell, terminal button, status badge, meta chips, prompt border |
| `web/src/components/SessionList.svelte` | Modify | Bottom padding for fab clearance |
| `web/src/App.svelte` | Modify | Header padding alignment |
| `signal/static/index.html` | Modify (via build) | Font preload link — added in `web/index.html` |
| `web/index.html` | Modify | Add font preload `<link>` |

---

### Task 1: Download and set up Nerd Font

**Files:**
- Create: `web/public/fonts/HackNerdFontMono-Regular.ttf`
- Modify: `web/src/app.css`
- Modify: `web/index.html`

- [ ] **Step 1: Create fonts directory and download the TTF**

```bash
mkdir -p web/public/fonts
curl -L -o web/public/fonts/HackNerdFontMono-Regular.ttf \
  "https://github.com/ryanoasis/nerd-fonts/raw/refs/tags/v3.4.0/patched-fonts/Hack/Regular/HackNerdFontMono-Regular.ttf"
```

Verify: `ls -la web/public/fonts/HackNerdFontMono-Regular.ttf` — should be ~400KB+.

- [ ] **Step 2: Add `@font-face` to `web/src/app.css`**

Add at the very top of the file, before the theme definitions:

```css
/* === Nerd Font (Powerline + icons) === */
@font-face {
  font-family: 'Hack Nerd Font Mono';
  src: url('/fonts/HackNerdFontMono-Regular.ttf') format('truetype');
  font-weight: normal;
  font-style: normal;
  font-display: swap;
}
```

- [ ] **Step 3: Add font preload to `web/index.html`**

Currently `web/index.html` looks like:

```html
<!DOCTYPE html>
<html lang="en" data-theme="cyber-dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Kite</title>
  ...
</head>
```

Read `web/index.html` first. Add a preload link after the `<title>` tag:

```html
<link rel="preload" href="/fonts/HackNerdFontMono-Regular.ttf" as="font" type="font/ttf" crossorigin>
```

- [ ] **Step 4: Build and verify font loads**

```bash
cd web && npm run build
```

Expected: Build succeeds. `signal/static/fonts/HackNerdFontMono-Regular.ttf` should exist (Vite copies `public/` contents to output).

- [ ] **Step 5: Commit**

```bash
git add web/public/fonts/HackNerdFontMono-Regular.ttf web/src/app.css web/index.html
git commit -m "feat: add self-hosted Hack Nerd Font for Powerline symbol support"
```

---

### Task 2: Global CSS updates (`app.css`)

**Files:**
- Modify: `web/src/app.css`

- [ ] **Step 1: Add `--nav-height` variable to each theme block**

In the `:root, [data-theme="cyber-dark"]` block, add at the end:

```css
  --nav-height: 2.5rem;
```

Repeat for `cyber-light`, `monokai`, `nord` blocks — same value in all four.

- [ ] **Step 2: Add body tweaks**

In the `body` rule, add `-webkit-text-size-adjust`:

```css
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  background: var(--bg);
  color: var(--fg);
  height: 100dvh;
  overflow: hidden;
  touch-action: manipulation;
  -webkit-text-size-adjust: 100%;
  transition: background-color 0.2s, color 0.2s;
}
```

- [ ] **Step 3: Add `will-change` to button transitions**

Update the global `button` rule:

```css
button {
  cursor: pointer;
  transition: transform 0.1s, background-color 0.15s, color 0.15s, border-color 0.15s, box-shadow 0.15s;
  will-change: transform;
}
```

- [ ] **Step 4: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds, no errors.

- [ ] **Step 5: Commit**

```bash
git add web/src/app.css
git commit -m "feat: global CSS updates — nav-height var, text-size-adjust, will-change"
```

---

### Task 3: TerminalView — accept fontSize prop and update fontFamily

**Files:**
- Modify: `web/src/components/TerminalView.svelte`

- [ ] **Step 1: Add `fontSize` prop**

Change the props line from:

```typescript
let { sessionId }: { sessionId: number } = $props();
```

to:

```typescript
let { sessionId, fontSize = 11 }: { sessionId: number; fontSize?: number } = $props();
```

- [ ] **Step 2: Update Terminal constructor to use the prop**

Replace the Terminal constructor block:

```typescript
terminal = new Terminal({
  fontSize: isMobile ? 12 : 14,
  fontFamily: "'Hack Nerd Font Mono', 'Fira Code', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace",
  theme: cssTheme,
  cursorBlink: true,
  scrollback: 5000,
  allowProposedApi: true,
});
```

with:

```typescript
terminal = new Terminal({
  fontSize,
  fontFamily: "'Hack Nerd Font Mono', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace",
  theme: cssTheme,
  cursorBlink: true,
  scrollback: 5000,
  allowProposedApi: true,
});
```

- [ ] **Step 3: Add reactive fontSize update**

After the `onMount` block and before `onDestroy`, add an `$effect` to react to fontSize changes:

```typescript
$effect(() => {
  if (terminal) {
    terminal.options.fontSize = fontSize;
    fitAddon?.fit();
  }
});
```

- [ ] **Step 4: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/TerminalView.svelte
git commit -m "feat: TerminalView accepts fontSize prop, use Hack Nerd Font Mono"
```

---

### Task 4: SessionDetail — full redesign

**Files:**
- Modify: `web/src/components/SessionDetail.svelte`

This is the largest task. It covers: remove PromptOverlay, remove status badge, add ConnectionStatus, add font size controls, add Enter button, add glow line, update padding.

- [ ] **Step 1: Update script — remove PromptOverlay, add font size state, add ConnectionStatus import**

Replace the entire `<script>` block with:

```typescript
<script lang="ts">
  import TerminalView from './TerminalView.svelte';
  import ConnectionStatus from './ConnectionStatus.svelte';
  import { sessionStore } from '../stores/sessions';
  import { transport, getPeerConnection } from '../lib/connection';
  import { onMount } from 'svelte';

  let { sessionId, onback }: { sessionId: number; onback: () => void } = $props();

  let session = $state<ReturnType<typeof sessionStore.getSession> | undefined>(undefined);
  let viewportHeight = $state(window.innerHeight);

  const FONT_STORAGE_KEY = 'kite-terminal-font-size';
  const FONT_DEFAULT = 11;
  const FONT_MIN = 8;
  const FONT_MAX = 18;

  function getStoredFontSize(): number {
    const v = localStorage.getItem(FONT_STORAGE_KEY);
    if (v) { const n = parseInt(v, 10); if (n >= FONT_MIN && n <= FONT_MAX) return n; }
    return FONT_DEFAULT;
  }

  let termFontSize = $state(getStoredFontSize());

  function adjustFont(delta: number) {
    const next = Math.max(FONT_MIN, Math.min(FONT_MAX, termFontSize + delta));
    if (next !== termFontSize) {
      termFontSize = next;
      localStorage.setItem(FONT_STORAGE_KEY, String(next));
    }
  }

  onMount(() => {
    const update = () => { session = sessionStore.getSession(sessionId); };
    update();
    const unsub = sessionStore.subscribe(update);

    function onViewportResize() {
      if (window.visualViewport) {
        viewportHeight = window.visualViewport.height;
      }
    }
    window.visualViewport?.addEventListener('resize', onViewportResize);

    return () => {
      unsub();
      window.visualViewport?.removeEventListener('resize', onViewportResize);
    };
  });

  function sendKey(key: string) { transport.send({ type: 'terminal_input', data: key, session_id: sessionId }); }
</script>
```

- [ ] **Step 2: Update template — new nav bar, remove PromptOverlay, add Enter button**

Replace everything from `<div class="detail"` to the closing `</div>` (the template section) with:

```svelte
<div class="detail" style:height="{viewportHeight}px">
  <nav>
    <button class="back" onclick={onback} aria-label="Back">&larr;</button>
    <span class="title">{session?.cwd?.split('/').pop() || `Session ${sessionId}`}</span>
    <div class="nav-right">
      <button class="font-btn" onclick={() => adjustFont(-1)} aria-label="Decrease font size">A-</button>
      <button class="font-btn" onclick={() => adjustFont(1)} aria-label="Increase font size">A+</button>
      <ConnectionStatus {getPeerConnection} />
    </div>
  </nav>

  <TerminalView {sessionId} fontSize={termFontSize} />

  <div class="actions">
    <button onclick={() => sendKey('\x03')}>Ctrl+C</button>
    <button onclick={() => sendKey('\t')}>Tab</button>
    <button onclick={() => sendKey('\x1b[A')}><span class="key-icon">&uarr;</span> Up</button>
    <button onclick={() => sendKey('\x1b[B')}><span class="key-icon">&darr;</span> Down</button>
    <button onclick={() => sendKey('\x1b')}>Esc</button>
    <button class="enter-btn" onclick={() => sendKey('\r')}><span class="key-icon">&crarr;</span> Enter</button>
  </div>
</div>
```

- [ ] **Step 3: Update styles**

Replace the entire `<style>` block with:

```svelte
<style>
  .detail { display: flex; flex-direction: column; position: relative; overflow: hidden; }
  nav {
    display: flex; align-items: center; gap: 0.3rem;
    padding: 0.35rem 0.6rem; padding-top: calc(0.35rem + env(safe-area-inset-top, 0px));
    background: var(--card-bg); flex-shrink: 0;
    position: relative;
    transition: background-color 0.2s;
  }
  nav::after {
    content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 1px;
    background: linear-gradient(90deg, transparent, var(--border-glow), var(--accent), var(--border-glow), transparent);
    opacity: 0.6;
  }
  .title {
    font-size: 0.85rem; color: var(--accent); flex: 1; font-weight: 600;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .back {
    background: none; border: none; color: var(--accent); font-size: 1rem;
    padding: 0; min-width: 36px; min-height: 36px;
    display: flex; align-items: center; justify-content: center;
  }
  .nav-right { display: flex; align-items: center; gap: 0.3rem; flex-shrink: 0; }
  .font-btn {
    background: none; border: 1px solid var(--border); border-radius: 6px;
    color: var(--text-secondary); font-size: 0.7rem; font-weight: 600;
    padding: 0.15rem 0.4rem; min-height: 28px; min-width: 28px;
    display: flex; align-items: center; justify-content: center;
    font-family: monospace;
  }
  .font-btn:hover { border-color: var(--accent); color: var(--accent); }
  .actions {
    display: flex; flex-shrink: 0;
    border-top: 1px solid var(--border); background: var(--card-bg);
    transition: background-color 0.2s, border-color 0.2s;
  }
  .actions button {
    flex: 1; padding: 0.6rem; border: none; border-right: 1px solid var(--border);
    background: transparent; color: var(--fg); font-size: 0.75rem;
    font-family: monospace; min-height: 44px;
    display: flex; align-items: center; justify-content: center; gap: 0.2rem;
  }
  .actions button:last-child { border-right: none; }
  .actions button:active { background: var(--border); }
  .key-icon { font-size: 0.85rem; line-height: 1; }
  .enter-btn {
    background: color-mix(in srgb, var(--accent) 10%, transparent) !important;
    color: var(--accent) !important;
  }
  .enter-btn:active {
    background: color-mix(in srgb, var(--accent) 25%, transparent) !important;
  }

  @media (min-width: 640px) {
    .detail { max-width: 960px; margin: 0 auto; width: 100%; }
  }
</style>
```

- [ ] **Step 4: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds. No references to PromptOverlay remain in SessionDetail.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/SessionDetail.svelte
git commit -m "feat: redesign SessionDetail — remove PromptOverlay/status, add ConnectionStatus/font controls/Enter key"
```

---

### Task 5: SessionCard visual polish

**Files:**
- Modify: `web/src/components/SessionCard.svelte`

- [ ] **Step 1: Update card border-radius and highlight line**

In the `<style>` block, change `.card` rule's `border-radius: 12px` to `border-radius: 10px`.

Change the `.card::after` highlight line from:

```css
  .card::after {
    content: ''; position: absolute; top: 0; left: 16px; right: 16px; height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255,255,255,0.12), transparent);
    pointer-events: none;
  }
```

to:

```css
  .card::after {
    content: ''; position: absolute; top: 0; left: 16px; right: 16px; height: 1px;
    background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--accent) 15%, transparent), transparent);
    pointer-events: none;
  }
```

- [ ] **Step 2: Add `:active` feedback to card**

Add after the `.card.running` rule:

```css
  .card:active {
    transform: translateY(-1px);
    box-shadow: 0 4px 8px rgba(0,0,0,0.3), 0 8px 24px rgba(0,0,0,0.2);
  }
```

- [ ] **Step 3: Update status badge — add slow breathing for running state**

Change `.status.running` from:

```css
  .status.running { background: rgba(102, 187, 106, 0.12); color: var(--success); border: 1px solid rgba(102, 187, 106, 0.2); }
```

to:

```css
  .status.running { background: rgba(102, 187, 106, 0.12); color: var(--success); border: 1px solid rgba(102, 187, 106, 0.2); animation: pulse-slow 2.5s infinite; }
```

Add the new keyframe after the existing `@keyframes pulse`:

```css
  @keyframes pulse-slow { 0%,100% { opacity:1 } 50% { opacity:.6 } }
```

- [ ] **Step 4: Update meta chips — icon opacity and hover**

Change `.meta-chip svg` from:

```css
  .meta-chip svg { opacity: 0.6; }
```

to:

```css
  .meta-chip svg { opacity: 0.75; }
  .meta-chip:hover { border-color: var(--accent); color: var(--accent); }
```

- [ ] **Step 5: Update terminal button — more prominent**

Change `.terminal-btn` from:

```css
  .terminal-btn {
    display: flex; align-items: center; gap: 0.3rem;
    padding: 0.3rem 0.75rem; border: none; border-radius: 8px;
    background: linear-gradient(135deg, rgba(79, 195, 247, 0.15), rgba(79, 195, 247, 0.05));
    color: var(--accent); font-size: 0.7rem;
    font-family: monospace; min-height: 32px;
    box-shadow: 0 0 0 1px var(--border-glow), 0 2px 8px rgba(0,0,0,0.2);
  }
```

to:

```css
  .terminal-btn {
    display: flex; align-items: center; gap: 0.3rem;
    padding: 0.35rem 0.85rem; border: 1px solid var(--accent); border-radius: 8px;
    background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 18%, transparent), color-mix(in srgb, var(--accent) 6%, transparent));
    color: var(--accent); font-size: 0.75rem; font-weight: 600;
    font-family: monospace; min-height: 34px;
    box-shadow: 0 0 0 1px var(--border-glow), 0 2px 8px rgba(0,0,0,0.2);
  }
```

- [ ] **Step 6: Update prompt section border**

Change `.prompt-section` from:

```css
  .prompt-section { padding-top: 0.4rem; border-top: 2px solid var(--warn); }
```

to:

```css
  .prompt-section { padding-top: 0.4rem; border-top: 1px solid var(--warn); }
```

- [ ] **Step 7: Update state-bar border-radius to match card**

Change `.state-bar` from:

```css
  .state-bar { width: 3px; flex-shrink: 0; border-radius: 12px 0 0 12px; }
```

to:

```css
  .state-bar { width: 3px; flex-shrink: 0; border-radius: 10px 0 0 10px; }
```

- [ ] **Step 8: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 9: Commit**

```bash
git add web/src/components/SessionCard.svelte
git commit -m "feat: SessionCard visual polish — border-radius, highlight, animations, button prominence"
```

---

### Task 6: SessionList, App header, and Fab button fixes

**Files:**
- Modify: `web/src/components/SessionList.svelte`
- Modify: `web/src/App.svelte`

- [ ] **Step 1: Add bottom padding to SessionList**

In `SessionList.svelte`, change the `.list` style from:

```css
  .list { flex: 1; overflow-y: auto; padding: 0.75rem; display: flex; flex-direction: column; gap: 0.5rem; -webkit-overflow-scrolling: touch; }
```

to:

```css
  .list { flex: 1; overflow-y: auto; padding: 0.75rem; padding-bottom: 4.5rem; display: flex; flex-direction: column; gap: 0.5rem; -webkit-overflow-scrolling: touch; }
```

- [ ] **Step 2: Update fab button for safe area and blur**

Change `.fab` from:

```css
  .fab {
    position: fixed; bottom: 1.5rem; right: 1.5rem; width: 48px; height: 48px;
    border-radius: 50%; border: none; color: #000;
    font-size: 1.4rem; font-weight: 700; z-index: 10;
    background: linear-gradient(135deg, var(--accent), color-mix(in srgb, var(--accent) 70%, #000));
    box-shadow: 0 2px 4px rgba(0,0,0,0.3), 0 4px 16px var(--glow-color);
  }
```

to:

```css
  .fab {
    position: fixed; bottom: calc(1.5rem + env(safe-area-inset-bottom, 0px)); right: 1.5rem;
    width: 48px; height: 48px;
    border-radius: 50%; border: none; color: #000;
    font-size: 1.4rem; font-weight: 700; z-index: 10;
    background: linear-gradient(135deg, var(--accent), color-mix(in srgb, var(--accent) 70%, #000));
    box-shadow: 0 2px 4px rgba(0,0,0,0.3), 0 4px 16px var(--glow-color);
    backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
  }
```

- [ ] **Step 3: Align App.svelte header padding**

In `App.svelte`, change the `header` style from:

```css
    padding: 0.2rem 0.5rem; padding-top: calc(0.2rem + env(safe-area-inset-top, 0px));
```

to:

```css
    padding: 0.35rem 0.6rem; padding-top: calc(0.35rem + env(safe-area-inset-top, 0px));
```

- [ ] **Step 4: Build and verify**

```bash
cd web && npm run build
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add web/src/components/SessionList.svelte web/src/App.svelte
git commit -m "feat: SessionList padding, fab safe-area/blur, header padding alignment"
```

---

### Task 7: Final build and verify

**Files:**
- Build output: `signal/static/`

- [ ] **Step 1: Full clean build**

```bash
cd web && npm run build
```

Expected: Build succeeds with no warnings.

- [ ] **Step 2: Verify build output contains font**

```bash
ls -la signal/static/fonts/HackNerdFontMono-Regular.ttf
```

Expected: File exists.

- [ ] **Step 3: Verify no PromptOverlay references in SessionDetail**

```bash
grep -n "PromptOverlay" web/src/components/SessionDetail.svelte
```

Expected: No output (no matches).

- [ ] **Step 4: Commit build output**

```bash
git add signal/static/
git commit -m "build: regenerate frontend with visual refresh changes"
```
