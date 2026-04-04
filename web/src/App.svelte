<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { rtc } from './lib/webrtc';
  import { onMount } from 'svelte';
  import {
    parsePairingFromHash,
    clearPairingFromHash,
    getStoredToken,
    setStoredToken,
    clearStoredToken,
    getStoredPairingCode,
    setStoredPairingCode,
    clearStoredPairingCode,
  } from './lib/auth';

  let currentView = $state<'list' | 'detail'>('list');
  let selectedSessionId = $state<number | null>(null);
  let authReady = $state(false);
  let authRequired = $state(false);
  let connecting = $state(false);
  let authError = $state('');
  let pairingInput = $state('');

  const signalUrl = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`;

  function handleAuthResult(msg: import('./lib/types').ServerMessage) {
    if (msg.type !== 'auth_result') return;
    console.log('[App] auth_result received, success:', msg.success);
    connecting = false;
    if (msg.success) {
      if (msg.token) setStoredToken(msg.token as string);
      authReady = true;
      authRequired = false;
      authError = '';
      console.log('[App] authReady=true, connecting=false');
    } else {
      clearStoredToken();
      authReady = false;
      authRequired = true;
      authError = 'Authentication failed.';
    }
  }

  onMount(() => {
    const unsubscribe = rtc.onMessage(handleAuthResult);

    void initializeAuth();

    return () => {
      unsubscribe();
      rtc.disconnect();
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
    // 1. Check URL hash for #/pair/{code}:{secret}
    const pairing = parsePairingFromHash();
    if (pairing) {
      clearPairingFromHash();
      connecting = true;
      try {
        await rtc.connect(signalUrl, pairing.pairingCode);
        setStoredPairingCode(pairing.pairingCode);
        if (await waitForOpen()) {
          rtc.authenticate(pairing.setupSecret);
        } else {
          connecting = false;
          authRequired = true;
          authError = 'Connection timed out.';
        }
      } catch {
        connecting = false;
        authRequired = true;
        authError = 'Failed to connect.';
      }
      return;
    }

    // 2. Check localStorage for session_token + pairing_code
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
          clearStoredToken();
          clearStoredPairingCode();
          authRequired = true;
          authError = 'Connection timed out. Re-pair with Kite.';
        }
      } catch {
        connecting = false;
        clearStoredToken();
        clearStoredPairingCode();
        authRequired = true;
        authError = 'Failed to connect.';
      }
      return;
    }

    // 3. Show pairing input
    authRequired = true;
  }

  async function submitPairing(input = pairingInput) {
    authError = '';
    const trimmed = input.trim();
    if (!trimmed) return;

    // Accept "code:secret" format
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
      if (await waitForOpen()) {
        rtc.authenticate(secret);
      } else {
        connecting = false;
        authError = 'Connection timed out.';
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

  function openSession(id: number) { selectedSessionId = id; currentView = 'detail'; }
  function goBack() { currentView = 'list'; selectedSessionId = null; }
</script>

<main>
  <header><h1>Kite</h1></header>

  {#if connecting}
    <section class="auth-card">
      <h2>Connecting...</h2>
      <p>Establishing secure connection to Kite.</p>
    </section>
  {:else if authRequired && !authReady}
    <section class="auth-card">
      <h2>Connect</h2>
      <p>Open the pairing link from `kite start`, or paste the pairing code here.</p>
      <div class="auth-row">
        <input
          type="text"
          bind:value={pairingInput}
          onkeydown={handleAuthKeydown}
          placeholder="code:secret"
        />
        <button onclick={() => submitPairing()}>Connect</button>
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
