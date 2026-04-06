# Frontend Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade Kite's mobile web UI with a multi-theme system (cyber/terminal aesthetic), smart-collapsing SessionCards, lightweight transitions, touch/a11y improvements, and responsive desktop support.

**Architecture:** CSS variable theming via `data-theme` attribute on `<html>`. Theme logic in a standalone `theme.ts` module. All visual changes are CSS-driven; component markup changes are limited to smart-collapse state and theme picker UI. No new dependencies.

**Tech Stack:** Svelte 5, Vite 6, TypeScript, xterm.js, CSS custom properties

**Build & dev:**
- `cd web && npm run dev` — dev server with HMR
- `cd web && npm run build` — production build to `signal/static/`
- After building, verify by opening the Vite dev server URL in a browser

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `web/src/lib/theme.ts` | Theme definitions, localStorage persistence, system preference listener, apply/get/toggle | Create |
| `web/src/app.css` | CSS variable definitions for all 4 themes + auto, global resets, transitions, reduced-motion, focus-visible, touch-action, responsive breakpoints | Modify |
| `web/src/App.svelte` | Theme picker dropdown in header, page slide transitions, Orbitron font on "Kite" title, header safe-area | Modify |
| `web/src/components/SessionCard.svelte` | Smart collapse (fold tasks/subagents by default, auto-expand prompt on waiting/asking), glassmorphism card, hardcoded color cleanup | Modify |
| `web/src/components/SessionList.svelte` | FAB glow, empty state redesign, responsive max-width | Modify |
| `web/src/components/SessionDetail.svelte` | Slide transition, action button touch targets (min-height 44px), status glow, responsive max-width | Modify |
| `web/src/components/TerminalView.svelte` | Read CSS variables on mount + listen for theme changes to update xterm theme | Modify |
| `web/src/components/PromptOverlay.svelte` | Glassmorphism, hardcoded color cleanup, button glow | Modify |
| `web/index.html` | Orbitron font preload link | Modify |

---

### Task 1: Create Theme Module (`theme.ts`)

**Files:**
- Create: `web/src/lib/theme.ts`

- [ ] **Step 1: Create theme.ts with type definitions and theme data**

```ts
export type ThemeId = 'cyber-dark' | 'cyber-light' | 'monokai' | 'nord' | 'auto';

export const THEME_LABELS: Record<ThemeId, string> = {
  'auto': 'Auto',
  'cyber-dark': 'Cyber Dark',
  'cyber-light': 'Cyber Light',
  'monokai': 'Monokai',
  'nord': 'Nord',
};

export const THEME_IDS: ThemeId[] = ['auto', 'cyber-dark', 'cyber-light', 'monokai', 'nord'];

const STORAGE_KEY = 'kite-theme';

export function getStoredTheme(): ThemeId {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored && stored in THEME_LABELS) return stored as ThemeId;
  return 'cyber-dark';
}

export function setStoredTheme(id: ThemeId): void {
  localStorage.setItem(STORAGE_KEY, id);
}

function resolveTheme(id: ThemeId): string {
  if (id !== 'auto') return id;
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'cyber-light' : 'cyber-dark';
}

export function applyTheme(id: ThemeId): void {
  const resolved = resolveTheme(id);
  document.documentElement.setAttribute('data-theme', resolved);
  setStoredTheme(id);
}

/** Call once on app init. Applies stored theme and sets up system preference listener. */
export function initTheme(): () => void {
  const stored = getStoredTheme();
  applyTheme(stored);

  const mql = window.matchMedia('(prefers-color-scheme: light)');
  const handler = () => {
    if (getStoredTheme() === 'auto') {
      applyTheme('auto');
    }
  };
  mql.addEventListener('change', handler);
  return () => mql.removeEventListener('change', handler);
}
```

- [ ] **Step 2: Verify the file compiles**

Run: `cd /Users/aneryu/kite/web && npx tsc --noEmit src/lib/theme.ts`
Expected: No errors (or only errors from missing svelte types, not from theme.ts itself)

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/lib/theme.ts
git commit -m "feat(web): add theme module with multi-theme support and system preference listener"
```

---

### Task 2: Define Theme CSS Variables in `app.css`

**Files:**
- Modify: `web/src/app.css`

- [ ] **Step 1: Replace entire app.css with theme variable definitions and global styles**

Replace the full contents of `web/src/app.css` with:

```css
/* === Theme Definitions === */

/* Cyber Dark (default) */
:root,
[data-theme="cyber-dark"] {
  --bg: #0a0a0a;
  --fg: #e0e0e0;
  --accent: #4fc3f7;
  --card-bg: #1a1a1a;
  --card-bg-alpha: rgba(255, 255, 255, 0.05);
  --border: #333;
  --border-glow: rgba(79, 195, 247, 0.2);
  --glow-color: rgba(79, 195, 247, 0.4);
  --danger: #ef5350;
  --success: #66bb6a;
  --warn: #ffa726;
  --text-secondary: #9aa0a6;
  --text-muted: #666;
}

/* Cyber Light */
[data-theme="cyber-light"] {
  --bg: #f0f2f5;
  --fg: #1a1a1a;
  --accent: #0288d1;
  --card-bg: #ffffff;
  --card-bg-alpha: rgba(255, 255, 255, 0.7);
  --border: #d0d0d0;
  --border-glow: rgba(2, 136, 209, 0.2);
  --glow-color: rgba(2, 136, 209, 0.3);
  --danger: #d32f2f;
  --success: #388e3c;
  --warn: #f57c00;
  --text-secondary: #666;
  --text-muted: #999;
}

/* Monokai */
[data-theme="monokai"] {
  --bg: #272822;
  --fg: #f8f8f2;
  --accent: #f92672;
  --card-bg: #3e3d32;
  --card-bg-alpha: rgba(62, 61, 50, 0.85);
  --border: #555;
  --border-glow: rgba(249, 38, 114, 0.2);
  --glow-color: rgba(249, 38, 114, 0.4);
  --danger: #f92672;
  --success: #a6e22e;
  --warn: #e6db74;
  --text-secondary: #a6a68a;
  --text-muted: #75715e;
}

/* Nord */
[data-theme="nord"] {
  --bg: #2e3440;
  --fg: #eceff4;
  --accent: #88c0d0;
  --card-bg: #3b4252;
  --card-bg-alpha: rgba(59, 66, 82, 0.85);
  --border: #4c566a;
  --border-glow: rgba(136, 192, 208, 0.2);
  --glow-color: rgba(136, 192, 208, 0.4);
  --danger: #bf616a;
  --success: #a3be8c;
  --warn: #ebcb8b;
  --text-secondary: #d8dee9;
  --text-muted: #7b88a1;
}

/* === Global Reset === */

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
  background: var(--bg);
  color: var(--fg);
  height: 100dvh;
  overflow: hidden;
  touch-action: manipulation;
  transition: background-color 0.2s, color 0.2s;
}

#app {
  display: flex;
  flex-direction: column;
  height: 100dvh;
}

/* === Global Focus Styles === */

:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

:focus:not(:focus-visible) {
  outline: none;
}

/* === Global Button Styles === */

button {
  cursor: pointer;
  transition: transform 0.1s, background-color 0.15s, color 0.15s, border-color 0.15s, box-shadow 0.15s;
}

button:active {
  transform: scale(0.96);
}

/* === Reduced Motion === */

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0s !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0s !important;
  }
}

/* === Glassmorphism Fallback === */

@supports not (backdrop-filter: blur(1px)) {
  .glass {
    background: var(--card-bg) !important;
  }
}
```

- [ ] **Step 2: Verify the dev server loads correctly**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds with no CSS errors

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/app.css
git commit -m "feat(web): define multi-theme CSS variables with global a11y and touch styles"
```

---

### Task 3: Add Orbitron Font and Theme Initialization to HTML + App.svelte

**Files:**
- Modify: `web/index.html`
- Modify: `web/src/App.svelte`

- [ ] **Step 1: Add Orbitron font preload to index.html**

Replace the full contents of `web/index.html` with:

```html
<!DOCTYPE html>
<html lang="en" data-theme="cyber-dark">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>Kite</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@700&display=swap" rel="stylesheet">
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.ts"></script>
</body>
</html>
```

- [ ] **Step 2: Update App.svelte — add theme imports, picker, header redesign, and page transitions**

Replace the full `<script>` section of `web/src/App.svelte` (lines 1-186) with:

```svelte
<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { rtc } from './lib/webrtc';
  import { onMount } from 'svelte';
  import { initTheme, applyTheme, getStoredTheme, THEME_IDS, THEME_LABELS, type ThemeId } from './lib/theme';
  import {
    parsePairingFromHash,
    clearPairingFromHash,
    getStoredToken,
    setStoredToken,
    clearStoredToken,
    getStoredPairingCode,
    setStoredPairingCode,
    clearStoredPairingCode,
    getStoredSecret,
    setStoredSecret,
    clearStoredSecret,
  } from './lib/auth';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);
  let authReady = $state(false);
  let authRequired = $state(false);
  let connecting = $state(false);
  let authError = $state('');
  let pairingInput = $state('');
  let waitingForDaemon = $state(false);
  let themeMenuOpen = $state(false);
  let currentTheme = $state<ThemeId>(getStoredTheme());
  let slideDirection = $state<'forward' | 'back'>('forward');

  const signalUrl = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`;

  let authRetried = false;

  function handleAuthResult(msg: import('./lib/types').ServerMessage) {
    if (msg.type !== 'auth_result') return;
    connecting = false;
    if (msg.success) {
      if (msg.token) setStoredToken(msg.token as string);
      authReady = true;
      authRequired = false;
      waitingForDaemon = false;
      authError = '';
      authRetried = false;
    } else {
      const secret = getStoredSecret();
      if (secret && !authRetried) {
        authRetried = true;
        rtc.authenticate(secret);
        return;
      }
      clearStoredToken();
      clearStoredSecret();
      clearStoredPairingCode();
      authReady = false;
      authRequired = true;
      waitingForDaemon = false;
      authError = 'Authentication failed. Please re-pair.';
      authRetried = false;
    }
  }

  onMount(() => {
    const cleanupTheme = initTheme();

    const unsubAuth = rtc.onMessage(handleAuthResult);
    const unsubSignal = rtc.onMessage((msg) => {
      if (msg.type === 'signal_connected') {
        waitingForDaemon = true;
        connecting = false;
      } else if (msg.type === 'daemon_disconnected') {
        waitingForDaemon = true;
        authReady = false;
      } else if (msg.type === 'auth_result' && msg.success) {
        waitingForDaemon = false;
      }
    });

    void initializeAuth();

    const handleClickOutside = (e: MouseEvent) => {
      if (themeMenuOpen && !(e.target as HTMLElement).closest('.theme-picker')) {
        themeMenuOpen = false;
      }
    };
    document.addEventListener('click', handleClickOutside);

    return () => {
      cleanupTheme();
      unsubAuth();
      unsubSignal();
      rtc.disconnect();
      document.removeEventListener('click', handleClickOutside);
    };
  });

  async function waitForOpen(timeout = 10000): Promise<boolean> {
    const start = Date.now();
    while (!rtc.isOpen()) {
      if (Date.now() - start > timeout) return false;
      await new Promise((r) => setTimeout(r, 100));
    }
    return true;
  }

  async function initializeAuth() {
    const pairing = parsePairingFromHash();
    if (pairing) {
      clearPairingFromHash();
      connecting = true;
      try {
        await rtc.connect(signalUrl, pairing.pairingCode);
        setStoredPairingCode(pairing.pairingCode);
        setStoredSecret(pairing.setupSecret);
        if (await waitForOpen()) {
          rtc.authenticate(pairing.setupSecret);
        } else {
          connecting = false;
          waitingForDaemon = true;
        }
      } catch {
        connecting = false;
        waitingForDaemon = true;
      }
      return;
    }

    const storedToken = getStoredToken();
    const storedCode = getStoredPairingCode();
    if (storedToken && storedCode) {
      connecting = true;
      try {
        await rtc.connect(signalUrl, storedCode);
        if (await waitForOpen()) {
          rtc.authenticate(storedToken);
        } else {
          connecting = false;
          waitingForDaemon = true;
        }
      } catch {
        connecting = false;
        waitingForDaemon = true;
      }
      return;
    }

    authRequired = true;
  }

  async function submitPairing(input = pairingInput) {
    authError = '';
    const trimmed = input.trim();
    if (!trimmed) return;

    const match = trimmed.match(/^([a-z0-9]{6}):([a-f0-9]{64})$/);
    if (!match) {
      authError = 'Invalid format. Expected code:secret (e.g. abc123:abcdef01...)';
      return;
    }

    const [, code, secret] = match;
    connecting = true;
    try {
      await rtc.connect(signalUrl, code);
      setStoredPairingCode(code);
      setStoredToken(secret);
      if (await waitForOpen()) {
        rtc.authenticate(secret);
      } else {
        connecting = false;
        waitingForDaemon = true;
      }
    } catch {
      connecting = false;
      authError = 'Failed to connect.';
    }
  }

  function handleAuthKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      void submitPairing();
    }
  }

  function selectTheme(id: ThemeId) {
    currentTheme = id;
    applyTheme(id);
    themeMenuOpen = false;
  }

  function openSession(id: number) {
    slideDirection = 'forward';
    selectedSessionId = id;
    currentView = 'detail';
  }
  function goBack() {
    slideDirection = 'back';
    currentView = 'list';
    selectedSessionId = null;
  }
</script>
```

- [ ] **Step 3: Replace the template section of App.svelte** (lines 188-223)

```svelte
<main>
  <header>
    <h1 class="brand">Kite</h1>
    <div class="theme-picker">
      <button class="theme-toggle" onclick={() => themeMenuOpen = !themeMenuOpen} aria-label="Change theme">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
      </button>
      {#if themeMenuOpen}
        <div class="theme-menu">
          {#each THEME_IDS as id}
            <button
              class="theme-item"
              class:active={currentTheme === id}
              onclick={() => selectTheme(id)}
            >{THEME_LABELS[id]}</button>
          {/each}
        </div>
      {/if}
    </div>
  </header>

  {#if connecting}
    <section class="auth-card glass">
      <h2>Connecting...</h2>
      <p>Establishing secure connection to Kite.</p>
    </section>
  {:else if waitingForDaemon && !authReady}
    <section class="auth-card glass">
      <h2>Waiting for daemon...</h2>
      <p>Connected to signal server. Waiting for Kite daemon to come online.</p>
    </section>
  {:else if authRequired && !authReady}
    <section class="auth-card glass">
      <h2>Connect</h2>
      <p>Open the pairing link from <code>kite start</code>, or paste the pairing code here.</p>
      <div class="auth-row">
        <input
          type="text"
          bind:value={pairingInput}
          onkeydown={handleAuthKeydown}
          placeholder="code:secret"
        />
        <button class="btn-primary" onclick={() => submitPairing()}>Connect</button>
      </div>
      {#if authError}
        <p class="error">{authError}</p>
      {/if}
    </section>
  {:else}
    <div class="view-container" class:slide-forward={slideDirection === 'forward'} class:slide-back={slideDirection === 'back'}>
      {#if currentView === 'list'}
        <SessionList onselect={openSession} />
      {:else if selectedSessionId}
        <SessionDetail sessionId={selectedSessionId} onback={goBack} />
      {/if}
    </div>
  {/if}
</main>
```

- [ ] **Step 4: Replace the style section of App.svelte** (lines 225-257)

```svelte
<style>
  main { display: flex; flex-direction: column; height: 100dvh; }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 0.75rem 1rem; padding-top: calc(0.75rem + env(safe-area-inset-top, 0px));
    background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0;
    transition: background-color 0.2s, border-color 0.2s;
  }
  .brand {
    font-family: 'Orbitron', sans-serif; font-size: 1rem; font-weight: 700;
    color: var(--accent); letter-spacing: 0.05em;
  }

  /* Theme picker */
  .theme-picker { position: relative; }
  .theme-toggle {
    background: none; border: 1px solid var(--border); border-radius: 6px;
    color: var(--text-secondary); padding: 0.3rem; display: flex; align-items: center;
    min-width: 44px; min-height: 44px; justify-content: center;
  }
  .theme-toggle:hover { border-color: var(--accent); color: var(--accent); }
  .theme-menu {
    position: absolute; top: 100%; right: 0; margin-top: 0.4rem;
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.25rem; z-index: 30; min-width: 160px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  }
  .theme-item {
    display: block; width: 100%; text-align: left; padding: 0.5rem 0.75rem;
    background: none; border: none; border-radius: 6px;
    color: var(--fg); font-size: 0.85rem; min-height: 44px;
    display: flex; align-items: center;
  }
  .theme-item:hover { background: var(--border); }
  .theme-item.active { color: var(--accent); }

  /* View transitions */
  .view-container { flex: 1; display: flex; flex-direction: column; overflow: hidden; }

  /* Auth card */
  .auth-card {
    width: min(32rem, calc(100vw - 2rem)); margin: 2rem auto; padding: 1rem;
    background: var(--card-bg-alpha); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    border: 1px solid var(--border-glow); border-radius: 12px;
    transition: background-color 0.2s, border-color 0.2s;
  }
  .auth-card h2 { margin: 0 0 0.5rem; font-size: 1rem; }
  .auth-card p { margin: 0 0 0.75rem; color: var(--text-secondary); line-height: 1.4; }
  .auth-card code { color: var(--accent); }
  .auth-row { display: flex; gap: 0.5rem; }
  .auth-row input {
    flex: 1; padding: 0.7rem 0.8rem; border-radius: 8px;
    border: 1px solid var(--border); background: var(--bg); color: var(--fg);
    font-size: 0.9rem; min-height: 44px;
  }
  .btn-primary {
    padding: 0.7rem 1rem; border: none; border-radius: 8px;
    background: var(--accent); color: #000; font-weight: 600;
    box-shadow: 0 0 12px var(--glow-color); min-height: 44px;
  }
  .error { color: var(--danger); }

  /* Responsive */
  @media (min-width: 640px) {
    .view-container { max-width: 640px; margin: 0 auto; width: 100%; }
  }
</style>
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
cd /Users/aneryu/kite
git add web/index.html web/src/App.svelte
git commit -m "feat(web): add theme picker, Orbitron brand font, glassmorphism auth cards"
```

---

### Task 4: Upgrade SessionCard with Smart Collapse and Visual Polish

**Files:**
- Modify: `web/src/components/SessionCard.svelte`

- [ ] **Step 1: Replace the full contents of SessionCard.svelte**

Replace the entire file with:

```svelte
<script lang="ts">
  import type { SessionInfo } from '../lib/types';
  import { sessionStore } from '../stores/sessions';
  import { rtc } from '../lib/webrtc';

  let { session, onterminal }: { session: SessionInfo; onterminal: () => void } = $props();
  let inputText = $state('');
  let selectedAnswers = $state<Record<string, string>>({});
  let questionInputs = $state<Record<string, string>>({});
  let tasksExpanded = $state(false);
  let agentsExpanded = $state(false);

  const prompt = $derived(sessionStore.prompts.get(session.id));
  const isAsking = $derived(session.state === 'asking' || session.state === 'waiting');
  const hasQuestions = $derived(prompt?.questions && prompt.questions.length > 0);
  const totalQuestions = $derived(prompt?.questions?.length ?? 0);

  function handleOption(e: Event, opt: string, questionText?: string) {
    e.stopPropagation();
    if (session.state === 'asking' && hasQuestions && questionText) {
      const updated = { ...selectedAnswers, [questionText]: opt };
      selectedAnswers = updated;
      if (Object.keys(updated).length >= totalQuestions) {
        rtc.sendPromptResponse(JSON.stringify(updated), session.id);
        selectedAnswers = {};
      }
    } else {
      rtc.sendPromptResponse(opt, session.id);
    }
  }

  function handleQuestionInput(e: Event, questionText: string) {
    e.stopPropagation();
    const text = (questionInputs[questionText] ?? '').trim();
    if (!text) return;
    questionInputs = { ...questionInputs, [questionText]: '' };
    handleOption(e, text, questionText);
  }

  function handleQuestionKeydown(e: KeyboardEvent, questionText: string) {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); handleQuestionInput(e, questionText); }
  }

  function handleSubmit(e: Event) {
    e.stopPropagation();
    if (!inputText.trim()) return;
    const text = inputText.trim();
    inputText = '';
    rtc.sendPromptResponse(text, session.id);
  }

  function handleKeydown(e: KeyboardEvent) {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); handleSubmit(e); }
  }

  function handleInputClick(e: Event) { e.stopPropagation(); }

  const completedTasks = $derived(session.tasks.filter((t) => t.completed).length);
  const runningAgents = $derived(session.subagents.filter((a) => !a.completed).length);

  function formatElapsed(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${Math.round(ms / 1000)}s`;
  }
</script>

<div class="card glass" class:waiting={isAsking}>
  <div class="row">
    <div class="title-group">
      <span class="sid">#{session.id}</span>
      <span class="title">{session.cwd.split('/').pop() || session.command}</span>
    </div>
    <div class="row-right">
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
      <button class="terminal-btn" onclick={onterminal}>Terminal</button>
    </div>
  </div>

  {#if session.activity}
    <div class="activity">{session.activity.tool_name}</div>
  {:else if session.last_message}
    <div class="last-msg">{session.last_message}</div>
  {/if}

  {#if session.tasks.length > 0}
    <button class="section-toggle" onclick={() => tasksExpanded = !tasksExpanded}>
      <span>Tasks: {completedTasks}/{session.tasks.length} done</span>
      <span class="chevron" class:open={tasksExpanded}></span>
    </button>
    {#if tasksExpanded}
      <div class="section-content">
        {#each session.tasks.slice(0, 5) as task}
          <div class="item" class:done={task.completed}>
            <span class="check">{task.completed ? '\u2713' : '\u2610'}</span>
            <span class="text">{task.subject}</span>
          </div>
        {/each}
        {#if session.tasks.length > 5}
          <div class="more">+{session.tasks.length - 5} more</div>
        {/if}
      </div>
    {/if}
  {/if}

  {#if session.subagents.length > 0}
    <button class="section-toggle" onclick={() => agentsExpanded = !agentsExpanded}>
      <span>Subagents: {runningAgents > 0 ? `${runningAgents} running` : `${session.subagents.length} done`}</span>
      <span class="chevron" class:open={agentsExpanded}></span>
    </button>
    {#if agentsExpanded}
      <div class="section-content">
        {#each session.subagents.slice(0, 4) as agent}
          <div class="item" class:done={agent.completed}>
            <span class="dot" class:running={!agent.completed}></span>
            <span class="text">{agent.type}</span>
            <span class="elapsed">{agent.completed ? formatElapsed(agent.elapsed_ms) : '...'}</span>
          </div>
        {/each}
        {#if session.subagents.length > 4}
          <div class="more">+{session.subagents.length - 4} more</div>
        {/if}
      </div>
    {/if}
  {/if}

  {#if isAsking && prompt}
    <div class="prompt-section">
      {#if prompt.questions && prompt.questions.length > 0}
        {#each prompt.questions as q}
          <div class="question-block" class:answered={q.question in selectedAnswers}>
            <div class="prompt-summary">{q.question}</div>
            {#if q.options.length > 0}
              <div class="prompt-options">
                {#each q.options as opt}
                  <button
                    class="prompt-opt"
                    class:selected={selectedAnswers[q.question] === opt}
                    onclick={(e) => handleOption(e, opt, q.question)}
                  >{opt}</button>
                {/each}
              </div>
            {/if}
            <div class="prompt-input">
              <input type="text"
                value={questionInputs[q.question] ?? ''}
                oninput={(e) => { questionInputs = { ...questionInputs, [q.question]: (e.target as HTMLInputElement).value }; }}
                onkeydown={(e) => handleQuestionKeydown(e, q.question)}
                onclick={handleInputClick}
                placeholder={selectedAnswers[q.question] ? selectedAnswers[q.question] : 'Type answer...'}
              />
              <button class="prompt-send" onclick={(e) => handleQuestionInput(e, q.question)}>OK</button>
            </div>
          </div>
        {/each}
      {:else}
        {#if prompt.summary}
          <div class="prompt-summary">{prompt.summary}</div>
        {/if}
        {#if prompt.options.length > 0}
          <div class="prompt-options">
            {#each prompt.options as opt}
              <button class="prompt-opt" onclick={(e) => handleOption(e, opt)}>{opt}</button>
            {/each}
          </div>
        {/if}
        <div class="prompt-input">
          <input type="text" bind:value={inputText} onkeydown={handleKeydown} onclick={handleInputClick} placeholder="Type a response..." />
          <button class="prompt-send" onclick={handleSubmit}>Send</button>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .card {
    display: block; width: 100%; text-align: left;
    background: var(--card-bg-alpha); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    border: 1px solid var(--border-glow); border-radius: 12px;
    padding: 0.85rem 1rem;
    color: var(--fg); font-family: inherit; font-size: inherit;
    transition: border-color 0.15s, background-color 0.2s, box-shadow 0.2s;
  }
  .card:hover { border-color: rgba(var(--accent), 0.4); }
  .card.waiting { border-color: var(--warn); box-shadow: 0 0 12px rgba(255, 167, 38, 0.15); }
  .row { display: flex; justify-content: space-between; align-items: center; }
  .row-right { display: flex; align-items: center; gap: 0.4rem; }
  .terminal-btn {
    padding: 0.2rem 0.6rem; border: 1px solid var(--accent); border-radius: 6px;
    background: transparent; color: var(--accent); font-size: 0.7rem;
    font-family: monospace; min-height: 32px; min-width: 44px;
    display: flex; align-items: center; justify-content: center;
  }
  .terminal-btn:active { background: var(--accent); color: #000; }
  .title-group { display: flex; align-items: center; gap: 0.4rem; min-width: 0; }
  .sid { color: var(--text-secondary); font-size: 0.7rem; font-family: monospace; flex-shrink: 0; }
  .title { font-weight: 600; font-size: 0.85rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .status { font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 4px; white-space: nowrap; }
  .status.running { background: var(--success); color: #000; box-shadow: 0 0 8px rgba(102, 187, 106, 0.3); }
  .status.waiting { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  .status.stopped { background: var(--text-muted); color: #fff; }
  .status.waiting_permission { background: var(--warn); color: #000; }
  .status.asking { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }

  .activity { color: var(--accent); font-size: 0.8rem; margin-top: 0.3rem; font-family: monospace; }
  .last-msg { color: var(--text-secondary); font-size: 0.75rem; margin-top: 0.3rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* Collapsible sections */
  .section-toggle {
    display: flex; justify-content: space-between; align-items: center; width: 100%;
    margin-top: 0.5rem; padding: 0.4rem 0; border: none; border-top: 1px solid var(--border);
    background: none; color: var(--text-secondary); font-size: 0.75rem; text-align: left;
  }
  .chevron { display: inline-block; width: 0; height: 0; border-left: 4px solid transparent; border-right: 4px solid transparent; border-top: 5px solid var(--text-secondary); transition: transform 0.15s; }
  .chevron.open { transform: rotate(180deg); }
  .section-content { overflow: hidden; }
  .item { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; padding: 0.1rem 0; }
  .item.done { opacity: 0.5; }
  .check { flex-shrink: 0; font-size: 0.75rem; color: var(--text-secondary); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--text-muted); flex-shrink: 0; }
  .dot.running { background: var(--success); box-shadow: 0 0 6px rgba(102, 187, 106, 0.5); }
  .text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .elapsed { color: var(--text-secondary); font-size: 0.7rem; flex-shrink: 0; }
  .more { color: var(--text-muted); font-size: 0.75rem; padding-left: 1.2rem; }

  /* Prompt section */
  .prompt-section { margin-top: 0.5rem; padding-top: 0.5rem; border-top: 2px solid var(--warn); }
  .question-block { margin-bottom: 0.6rem; }
  .question-block:last-of-type { margin-bottom: 0; }
  .question-block.answered { opacity: 0.5; }
  .prompt-summary { font-size: 0.8rem; color: var(--fg); margin-bottom: 0.4rem; max-height: 2.5rem; overflow: hidden; text-overflow: ellipsis; white-space: pre-wrap; word-break: break-word; }
  .prompt-options { display: flex; gap: 0.4rem; margin-bottom: 0.4rem; flex-wrap: wrap; }
  .prompt-opt { padding: 0.3rem 0.8rem; border: 1px solid var(--accent); border-radius: 16px; background: transparent; color: var(--accent); font-size: 0.8rem; transition: background 0.1s, color 0.1s; min-height: 36px; }
  .prompt-opt:active { background: var(--accent); color: #000; }
  .prompt-opt.selected { background: var(--accent); color: #000; }
  .prompt-input { display: flex; gap: 0.4rem; }
  .prompt-input input { flex: 1; padding: 0.4rem 0.6rem; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg); font-size: 0.8rem; min-height: 36px; }
  .prompt-input input:focus { border-color: var(--accent); }
  .prompt-send { padding: 0.4rem 0.7rem; border: none; border-radius: 6px; background: var(--accent); color: #000; font-weight: 600; font-size: 0.8rem; box-shadow: 0 0 8px var(--glow-color); min-height: 36px; }
</style>
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/components/SessionCard.svelte
git commit -m "feat(web): smart-collapse SessionCard with glassmorphism and semantic colors"
```

---

### Task 5: Upgrade SessionList — FAB Glow and Empty State

**Files:**
- Modify: `web/src/components/SessionList.svelte`

- [ ] **Step 1: Replace the full contents of SessionList.svelte**

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import SessionCard from './SessionCard.svelte';
  import { sessionStore } from '../stores/sessions';
  import { rtc } from '../lib/webrtc';

  let { onselect }: { onselect: (id: number) => void } = $props();
  let sessions = $state(sessionStore.sorted());

  onMount(() => {
    const unsub = sessionStore.subscribe(() => { sessions = sessionStore.sorted(); });
    return () => { unsub(); };
  });

  function handleCreate() {
    rtc.createSession();
  }
</script>

<div class="list">
  {#each sessions as session (session.id)}
    <SessionCard {session} onterminal={() => onselect(session.id)} />
  {/each}
  {#if sessions.length === 0}
    <div class="empty">
      <svg class="empty-icon" width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="4 17 10 11 4 5"></polyline>
        <line x1="12" y1="19" x2="20" y2="19"></line>
      </svg>
      <p class="empty-title">No active sessions</p>
      <p class="empty-sub">Run <code>kite run</code> to start a session, or tap + below</p>
    </div>
  {/if}
</div>
<button class="fab" onclick={handleCreate} aria-label="Create session">+</button>

<style>
  .list { flex: 1; overflow-y: auto; padding: 0.75rem; display: flex; flex-direction: column; gap: 0.5rem; -webkit-overflow-scrolling: touch; }
  .empty { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 3rem 1rem; gap: 0.5rem; }
  .empty-icon { color: var(--text-muted); }
  .empty-title { color: var(--text-secondary); font-size: 1rem; font-weight: 600; }
  .empty-sub { color: var(--text-muted); font-size: 0.85rem; text-align: center; }
  .empty-sub code { color: var(--accent); }
  .fab {
    position: fixed; bottom: 1.5rem; right: 1.5rem; width: 52px; height: 52px;
    border-radius: 50%; border: none; background: var(--accent); color: #000;
    font-size: 1.5rem; font-weight: 700; z-index: 10;
    box-shadow: 0 2px 8px rgba(0,0,0,0.4), 0 0 16px var(--glow-color);
  }

  @media (min-width: 640px) {
    .list { max-width: 640px; margin: 0 auto; width: 100%; }
    .fab { right: calc(50% - 320px + 1.5rem); }
  }
</style>
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/components/SessionList.svelte
git commit -m "feat(web): FAB glow, redesigned empty state, responsive max-width"
```

---

### Task 6: Upgrade SessionDetail — Touch Targets, Status Glow, Responsive

**Files:**
- Modify: `web/src/components/SessionDetail.svelte`

- [ ] **Step 1: Replace the full contents of SessionDetail.svelte**

```svelte
<script lang="ts">
  import TerminalView from './TerminalView.svelte';
  import PromptOverlay from './PromptOverlay.svelte';
  import { sessionStore } from '../stores/sessions';
  import { rtc } from '../lib/webrtc';
  import { onMount } from 'svelte';

  let { sessionId, onback }: { sessionId: number; onback: () => void } = $props();

  let session = $state<ReturnType<typeof sessionStore.getSession> | undefined>(undefined);

  onMount(() => {
    const update = () => { session = sessionStore.getSession(sessionId); };
    update();
    const unsub = sessionStore.subscribe(update);
    return unsub;
  });

  function handlePromptSubmit(text: string) { rtc.sendPromptResponse(text, sessionId); }
  function sendKey(key: string) { rtc.sendTerminalInput(key, sessionId); }
</script>

<div class="detail">
  <header>
    <button class="back" onclick={onback} aria-label="Back">&larr;</button>
    <h1>{session?.cwd?.split('/').pop() || `Session ${sessionId}`}</h1>
    {#if session}
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
    {/if}
  </header>

  <TerminalView {sessionId} />

  <div class="actions">
    <button onclick={() => sendKey('\x03')}>Ctrl+C</button>
    <button onclick={() => sendKey('\t')}>Tab</button>
    <button onclick={() => sendKey('\x1b[A')}>Up</button>
    <button onclick={() => sendKey('\x1b[B')}>Down</button>
    <button onclick={() => sendKey('\x1b')}>Esc</button>
  </div>

  {#if session?.state === 'waiting' || session?.state === 'asking'}
    {@const prompt = sessionStore.prompts.get(sessionId)}
    <PromptOverlay
      options={prompt?.options ?? []}
      summary={prompt?.summary ?? ''}
      onsubmit={handlePromptSubmit}
    />
  {/if}
</div>

<style>
  .detail { display: flex; flex-direction: column; height: 100dvh; position: relative; }
  header {
    display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 1rem;
    background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0;
    transition: background-color 0.2s, border-color 0.2s;
  }
  header h1 { font-size: 1rem; color: var(--accent); flex: 1; }
  .back {
    background: none; border: none; color: var(--accent); font-size: 1.2rem;
    padding: 0; min-width: 44px; min-height: 44px;
    display: flex; align-items: center; justify-content: center;
  }
  .status { font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 4px; white-space: nowrap; }
  .status.running { background: var(--success); color: #000; box-shadow: 0 0 8px rgba(102, 187, 106, 0.3); }
  .status.waiting { background: var(--warn); color: #000; }
  .status.stopped { background: var(--text-muted); color: #fff; }
  .status.waiting_permission { background: var(--warn); color: #000; }
  .status.asking { background: var(--warn); color: #000; }
  .actions {
    display: flex; flex-shrink: 0;
    border-top: 1px solid var(--border); background: var(--card-bg);
    transition: background-color 0.2s, border-color 0.2s;
  }
  .actions button {
    flex: 1; padding: 0.6rem; border: none; border-right: 1px solid var(--border);
    background: transparent; color: var(--fg); font-size: 0.8rem;
    font-family: monospace; min-height: 44px;
  }
  .actions button:last-child { border-right: none; }
  .actions button:active { background: var(--border); }

  @media (min-width: 640px) {
    .detail { max-width: 960px; margin: 0 auto; width: 100%; }
  }
</style>
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/components/SessionDetail.svelte
git commit -m "feat(web): SessionDetail touch targets, status glow, responsive layout"
```

---

### Task 7: Upgrade PromptOverlay — Glassmorphism, Color Cleanup

**Files:**
- Modify: `web/src/components/PromptOverlay.svelte`

- [ ] **Step 1: Replace the full contents of PromptOverlay.svelte**

```svelte
<script lang="ts">
  let { options = [], summary = '', onsubmit }: { options?: string[]; summary?: string; onsubmit: (text: string) => void } = $props();
  let inputText = $state('');

  function handleSubmit() {
    if (inputText.trim()) { onsubmit(inputText.trim()); inputText = ''; }
  }

  function handleOption(opt: string) { onsubmit(opt); }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSubmit(); }
  }
</script>

<div class="overlay">
  <div class="prompt-bar glass">
    {#if summary}
      <div class="summary">{summary}</div>
    {/if}
    {#if options.length > 0}
      <div class="options">
        {#each options as opt}
          <button class="opt-btn" onclick={() => handleOption(opt)}>{opt}</button>
        {/each}
      </div>
    {/if}
    <div class="input-row">
      <input type="text" bind:value={inputText} onkeydown={handleKeydown} placeholder="Type a response..." />
      <button class="send-btn" onclick={handleSubmit}>Send</button>
    </div>
  </div>
</div>

<style>
  .overlay { position: absolute; bottom: 0; left: 0; right: 0; z-index: 20; padding-bottom: env(safe-area-inset-bottom, 0); }
  .prompt-bar {
    background: var(--card-bg-alpha); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    border-top: 2px solid var(--warn); padding: 0.75rem;
    transition: background-color 0.2s, border-color 0.2s;
  }
  .summary { font-size: 0.85rem; color: var(--fg); margin-bottom: 0.5rem; max-height: 3rem; overflow-y: auto; white-space: pre-wrap; word-break: break-word; }
  .options { display: flex; gap: 0.5rem; margin-bottom: 0.5rem; flex-wrap: wrap; }
  .opt-btn {
    padding: 0.4rem 1rem; border: 1px solid var(--accent); border-radius: 20px;
    background: transparent; color: var(--accent); font-size: 0.85rem;
    transition: background 0.1s, color 0.1s; min-height: 36px;
  }
  .opt-btn:active { background: var(--accent); color: #000; }
  .input-row { display: flex; gap: 0.5rem; }
  input {
    flex: 1; padding: 0.6rem 0.8rem; border: 1px solid var(--border); border-radius: 8px;
    background: var(--bg); color: var(--fg); font-size: 0.9rem; min-height: 44px;
  }
  input:focus { border-color: var(--accent); }
  .send-btn {
    padding: 0.6rem 1rem; border: none; border-radius: 8px;
    background: var(--accent); color: #000; font-weight: 600;
    box-shadow: 0 0 8px var(--glow-color); min-height: 44px;
  }
</style>
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/components/PromptOverlay.svelte
git commit -m "feat(web): PromptOverlay glassmorphism and semantic color tokens"
```

---

### Task 8: TerminalView Theme Sync

**Files:**
- Modify: `web/src/components/TerminalView.svelte`

- [ ] **Step 1: Replace the full contents of TerminalView.svelte**

```svelte
<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import { Unicode11Addon } from '@xterm/addon-unicode11';
  import '@xterm/xterm/css/xterm.css';
  import { rtc } from '../lib/webrtc';
  import type { ServerMessage } from '../lib/types';

  let { sessionId }: { sessionId: number } = $props();
  let containerEl: HTMLDivElement;
  let terminal: Terminal;
  let fitAddon: FitAddon;
  let unsubscribe: (() => void) | null = null;
  let resizeObserver: ResizeObserver | null = null;
  let themeObserver: MutationObserver | null = null;

  function readCssTheme(): { background: string; foreground: string; cursor: string } {
    const style = getComputedStyle(document.documentElement);
    return {
      background: style.getPropertyValue('--bg').trim() || '#0a0a0a',
      foreground: style.getPropertyValue('--fg').trim() || '#e0e0e0',
      cursor: style.getPropertyValue('--accent').trim() || '#4fc3f7',
    };
  }

  onMount(async () => {
    const cssTheme = readCssTheme();
    terminal = new Terminal({
      fontSize: 14,
      fontFamily: "'Hack Nerd Font Mono', 'Fira Code', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace",
      theme: cssTheme,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
    });
    fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    try {
      const unicode11 = new Unicode11Addon();
      terminal.loadAddon(unicode11);
      terminal.unicode.activeVersion = '11';
    } catch (e) {
      console.warn('Unicode11 addon failed to load:', e);
    }
    terminal.open(containerEl);

    function base64ToBytes(b64: string): Uint8Array {
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    }

    unsubscribe = rtc.onMessage((msg: ServerMessage) => {
      if (msg.type === 'terminal_output' && msg.session_id === sessionId && msg.data) {
        terminal.write(base64ToBytes(msg.data));
      }
    });

    terminal.onData((data: string) => { rtc.sendTerminalInput(data, sessionId); });

    let snapshotRequested = false;
    function doFitAndResize() {
      const rect = containerEl.getBoundingClientRect();
      console.log('[TerminalView] doFitAndResize: container rect=', rect.width, 'x', rect.height);
      fitAddon.fit();
      console.log('[TerminalView] after fit: cols=', terminal.cols, 'rows=', terminal.rows);
      if (terminal.cols === 0 || terminal.rows === 0) {
        console.log('[TerminalView] cols/rows is 0, retrying next frame');
        requestAnimationFrame(doFitAndResize);
        return;
      }
      rtc.sendResize(terminal.cols, terminal.rows, sessionId);
      if (!snapshotRequested) {
        snapshotRequested = true;
        rtc.requestSnapshot(sessionId);
      }
    }
    resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      console.log('[TerminalView] ResizeObserver fired: contentRect=', entry.contentRect.width, 'x', entry.contentRect.height);
      doFitAndResize();
    });
    resizeObserver.observe(containerEl);

    // Watch for theme changes (data-theme attribute on <html>)
    themeObserver = new MutationObserver(() => {
      terminal.options.theme = readCssTheme();
    });
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  });

  onDestroy(() => {
    unsubscribe?.();
    resizeObserver?.disconnect();
    themeObserver?.disconnect();
    terminal?.dispose();
  });
</script>

<div class="terminal-container" bind:this={containerEl}></div>

<style>
  .terminal-container { flex: 1; overflow: hidden; }
</style>
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/aneryu/kite/web && npx vite build 2>&1 | tail -5`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
cd /Users/aneryu/kite
git add web/src/components/TerminalView.svelte
git commit -m "feat(web): sync xterm.js theme with CSS variables on theme change"
```

---

### Task 9: Build Production Bundle and Verify

**Files:**
- Outputs to: `signal/static/`

- [ ] **Step 1: Install dependencies if needed**

Run: `cd /Users/aneryu/kite/web && npm install`
Expected: Dependencies installed (or already up to date)

- [ ] **Step 2: Build production bundle**

Run: `cd /Users/aneryu/kite/web && npm run build`
Expected: Build succeeds, files written to `signal/static/`

- [ ] **Step 3: Verify output files exist**

Run: `ls -la /Users/aneryu/kite/signal/static/`
Expected: `index.html` and `assets/` directory with `.js` and `.css` files

- [ ] **Step 4: Verify index.html includes Orbitron font link**

Run: `grep -c 'Orbitron' /Users/aneryu/kite/signal/static/index.html`
Expected: At least 1 match

- [ ] **Step 5: Commit the production build**

```bash
cd /Users/aneryu/kite
git add signal/static/
git commit -m "build(web): production bundle with multi-theme and UI polish"
```
