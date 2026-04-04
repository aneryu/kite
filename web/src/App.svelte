<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { ws } from './lib/ws';
  import { onMount } from 'svelte';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);

  onMount(() => { ws.connect(); return () => ws.disconnect(); });

  function openSession(id: number) { selectedSessionId = id; currentView = 'detail'; }
  function goBack() { currentView = 'list'; selectedSessionId = null; }
</script>

<main>
  {#if currentView === 'list'}
    <header><h1>Kite</h1></header>
    <SessionList onselect={openSession} />
  {:else if selectedSessionId}
    <SessionDetail sessionId={selectedSessionId} onback={goBack} />
  {/if}
</main>

<style>
  header { display: flex; align-items: center; gap: 0.5rem; padding: 0.5rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
  header h1 { font-size: 1rem; color: var(--accent); }
  main { display: flex; flex-direction: column; height: 100dvh; }
</style>
