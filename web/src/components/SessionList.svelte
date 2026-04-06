<script lang="ts">
  import { onMount } from 'svelte';
  import SessionCard from './SessionCard.svelte';
  import { sessionStore } from '../stores/sessions';
  import { transport } from '../lib/connection';

  let { onselect }: { onselect: (id: number) => void } = $props();
  let sessions = $state(sessionStore.sorted());

  onMount(() => {
    const unsub = sessionStore.subscribe(() => { sessions = sessionStore.sorted(); });
    return () => { unsub(); };
  });

  function handleCreate() {
    transport.send({ type: 'create_session', data: 'claude' });
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
    position: fixed; bottom: 1.5rem; right: 1.5rem; width: 48px; height: 48px;
    border-radius: 50%; border: none; color: #000;
    font-size: 1.4rem; font-weight: 700; z-index: 10;
    background: linear-gradient(135deg, var(--accent), color-mix(in srgb, var(--accent) 70%, #000));
    box-shadow: 0 2px 4px rgba(0,0,0,0.3), 0 4px 16px var(--glow-color);
  }

  @media (min-width: 640px) {
    .list { max-width: 640px; margin: 0 auto; width: 100%; }
    .fab { right: calc(50% - 320px + 1.5rem); }
  }
</style>
