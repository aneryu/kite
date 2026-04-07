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
