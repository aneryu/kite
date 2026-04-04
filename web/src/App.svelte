<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { ws } from './lib/ws';
  import { onMount } from 'svelte';
  import { clearSetupTokenFromUrl, clearStoredToken, getSetupTokenFromUrl, getStoredToken, setStoredToken } from './lib/auth';
  import { exchangeSetupToken, fetchSessions } from './lib/api';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);
  let authReady = $state(false);
  let authRequired = $state(false);
  let authError = $state('');
  let setupTokenInput = $state('');

  onMount(() => {
    const unsubscribe = ws.onMessage((msg) => {
      if (msg.type !== 'auth_result') return;
      if (msg.success) {
        authReady = true;
        authRequired = false;
        authError = '';
      } else {
        clearStoredToken();
        authReady = false;
        authRequired = true;
        authError = 'Authentication failed. Use a fresh setup token.';
      }
    });

    ws.connect();
    void initializeAuth();

    return () => {
      unsubscribe();
      ws.disconnect();
    };
  });

  async function initializeAuth() {
    const urlToken = getSetupTokenFromUrl();
    if (urlToken) {
      setupTokenInput = urlToken;
      await submitSetupToken(urlToken);
      clearSetupTokenFromUrl();
      return;
    }

    const storedToken = getStoredToken();
    if (storedToken) {
      ws.authenticate(storedToken);
      try {
        await fetchSessions();
        authReady = true;
        authRequired = false;
        return;
      } catch {
        clearStoredToken();
        authRequired = true;
      }
    }

    try {
      await fetchSessions();
      authReady = true;
      authRequired = false;
    } catch (error) {
      authReady = false;
      authRequired = true;
      authError = error instanceof Error && error.message === 'HTTP 401' ? '' : 'Unable to reach Kite.';
    }
  }

  async function submitSetupToken(token = setupTokenInput) {
    authError = '';
    const trimmed = token.trim();
    if (!trimmed) return;

    try {
      const sessionToken = await exchangeSetupToken(trimmed);
      setStoredToken(sessionToken);
      authReady = true;
      authRequired = false;
      setupTokenInput = '';
      ws.authenticate(sessionToken);
      await fetchSessions();
    } catch {
      authReady = false;
      authRequired = true;
      authError = 'Setup token is invalid or expired.';
    }
  }

  function handleAuthKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      void submitSetupToken();
    }
  }

  function openSession(id: number) { selectedSessionId = id; currentView = 'detail'; }
  function goBack() { currentView = 'list'; selectedSessionId = null; }
</script>

<main>
  <header><h1>Kite</h1></header>

  {#if authRequired && !authReady}
    <section class="auth-card">
      <h2>Connect</h2>
      <p>Open the setup link from `kite start`, or paste the setup token here.</p>
      <div class="auth-row">
        <input
          type="text"
          bind:value={setupTokenInput}
          onkeydown={handleAuthKeydown}
          placeholder="Paste setup token"
        />
        <button onclick={() => submitSetupToken()}>Unlock</button>
      </div>
      {#if authError}
        <p class="error">{authError}</p>
      {/if}
    </section>
  {:else if currentView === 'list'}
    <SessionList onselect={openSession} />
  {:else if selectedSessionId}
    <SessionDetail sessionId={selectedSessionId} onback={goBack} />
  {/if}
</main>

<style>
  header { display: flex; align-items: center; gap: 0.5rem; padding: 0.75rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
  header h1 { font-size: 1rem; color: var(--accent); }
  main { display: flex; flex-direction: column; height: 100dvh; }
  .auth-card {
    width: min(32rem, calc(100vw - 2rem));
    margin: 2rem auto;
    padding: 1rem;
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 12px;
  }
  .auth-card h2 { margin: 0 0 0.5rem; font-size: 1rem; }
  .auth-card p { margin: 0 0 0.75rem; color: #9aa0a6; line-height: 1.4; }
  .auth-row { display: flex; gap: 0.5rem; }
  .auth-row input {
    flex: 1;
    padding: 0.7rem 0.8rem;
    border-radius: 8px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--fg);
  }
  .auth-row button {
    padding: 0.7rem 1rem;
    border: none;
    border-radius: 8px;
    background: var(--accent);
    color: #000;
    font-weight: 600;
  }
  .error { color: #ff7b72; }
</style>
