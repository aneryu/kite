<script lang="ts">
  import TerminalView from './TerminalView.svelte';
  import PromptOverlay from './PromptOverlay.svelte';
  import { sessionStore } from '../stores/sessions';
  import { ws } from '../lib/ws';
  import { onMount } from 'svelte';

  let { sessionId, onback }: { sessionId: number; onback: () => void } = $props();

  let session = $state(sessionStore.getSession(sessionId));

  onMount(() => {
    const unsub = sessionStore.subscribe(() => { session = sessionStore.getSession(sessionId); });
    return unsub;
  });

  function handlePromptSubmit(text: string) { ws.sendPromptResponse(text, sessionId); }
  function sendKey(key: string) { ws.sendTerminalInput(key, sessionId); }
</script>

<div class="detail">
  <header>
    <button class="back" onclick={onback}>&larr;</button>
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

  {#if session?.state === 'waiting_input' || session?.state === 'asking'}
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
  header { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
  header h1 { font-size: 1rem; color: var(--accent); flex: 1; }
  .back { background: none; border: none; color: var(--accent); font-size: 1.2rem; cursor: pointer; padding: 0 0.5rem; }
  .status { font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 4px; }
  .status.running { background: var(--success); color: #000; }
  .status.waiting_input { background: var(--warn); color: #000; }
  .status.stopped { background: var(--danger); color: #fff; }
  .status.starting { background: var(--accent); color: #000; }
  .status.idle { background: var(--accent); color: #000; }
  .status.asking { background: var(--warn); color: #000; }
  .actions { display: flex; gap: 0; flex-shrink: 0; border-top: 1px solid var(--border); background: var(--card-bg); }
  .actions button { flex: 1; padding: 0.6rem; border: none; border-right: 1px solid var(--border); background: transparent; color: var(--fg); font-size: 0.8rem; cursor: pointer; font-family: monospace; }
  .actions button:last-child { border-right: none; }
  .actions button:active { background: var(--border); }
</style>
