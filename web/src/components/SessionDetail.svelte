<script lang="ts">
  import TerminalView from './TerminalView.svelte';
  import PromptOverlay from './PromptOverlay.svelte';
  import { sessionStore } from '../stores/sessions';
  import { rtc } from '../lib/webrtc';
  import { onMount } from 'svelte';

  let { sessionId, onback }: { sessionId: number; onback: () => void } = $props();

  let session = $state<ReturnType<typeof sessionStore.getSession> | undefined>(undefined);
  let viewportHeight = $state(window.innerHeight);

  onMount(() => {
    const update = () => { session = sessionStore.getSession(sessionId); };
    update();
    const unsub = sessionStore.subscribe(update);

    // Use visualViewport to track keyboard height — shrink the whole container
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

  function handlePromptSubmit(text: string) { rtc.sendPromptResponse(text, sessionId); }
  function sendKey(key: string) { rtc.sendTerminalInput(key, sessionId); }
</script>

<div class="detail" style:height="{viewportHeight}px">
  <header>
    <button class="back" onclick={onback} aria-label="Back">&larr;</button>
    <h1>{session?.cwd?.split('/').pop() || `Session ${sessionId}`}</h1>
    {#if session}
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
    {/if}
  </header>

  <TerminalView {sessionId} />

  {#if session?.state === 'asking'}
    {@const prompt = sessionStore.prompts.get(sessionId)}
    <PromptOverlay
      options={prompt?.options ?? []}
      summary={prompt?.summary ?? ''}
      onsubmit={handlePromptSubmit}
    />
  {/if}

  <div class="actions">
    <button onclick={() => sendKey('\x03')}>Ctrl+C</button>
    <button onclick={() => sendKey('\t')}>Tab</button>
    <button onclick={() => sendKey('\x1b[A')}>Up</button>
    <button onclick={() => sendKey('\x1b[B')}>Down</button>
    <button onclick={() => sendKey('\x1b')}>Esc</button>
  </div>
</div>

<style>
  .detail { display: flex; flex-direction: column; position: relative; overflow: hidden; }
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
