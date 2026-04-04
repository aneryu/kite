<script lang="ts">
  import { onMount } from 'svelte';
  import SessionCard from './SessionCard.svelte';
  import { sessionStore } from '../stores/sessions';
  import { createSession } from '../lib/api';

  let { onselect }: { onselect: (id: number) => void } = $props();
  let sessions = $state(sessionStore.sorted());

  onMount(() => {
    sessionStore.load();
    const unsub = sessionStore.subscribe(() => { sessions = sessionStore.sorted(); });
    const interval = setInterval(() => sessionStore.load(), 5000);
    return () => { unsub(); clearInterval(interval); };
  });

  async function handleCreate() {
    try { await createSession(); await sessionStore.load(); } catch {}
  }
</script>

<div class="list">
  {#each sessions as session (session.id)}
    <SessionCard {session} onterminal={() => onselect(session.id)} />
  {/each}
  {#if sessions.length === 0}
    <p class="empty">No sessions. Create one with <code>kite run</code> or tap +</p>
  {/if}
</div>
<button class="fab" onclick={handleCreate}>+</button>

<style>
  .list { flex: 1; overflow-y: auto; padding: 0.75rem; display: flex; flex-direction: column; gap: 0.5rem; -webkit-overflow-scrolling: touch; }
  .empty { text-align: center; color: #666; padding: 2rem; }
  .empty code { color: var(--accent); }
  .fab { position: fixed; bottom: 1.5rem; right: 1.5rem; width: 52px; height: 52px; border-radius: 50%; border: none; background: var(--accent); color: #000; font-size: 1.5rem; font-weight: 700; cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.4); z-index: 10; }
</style>
