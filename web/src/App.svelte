<script lang="ts">
  import SessionList from './components/SessionList.svelte';
  import SessionDetail from './components/SessionDetail.svelte';
  import { transport, connect, authenticate, disconnect, isConnected, onAppEvent, getPeerConnection } from './lib/connection';
  import ConnectionStatus from './components/ConnectionStatus.svelte';
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

  const url = URL.parse(location.href);
  const host = url.searchParams.get('host') || 'relay.fun.dev';
  const signalUrl = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${host}/ws`;

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
        authenticate(secret);
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

    const unsubAuth = transport.onMessage(handleAuthResult);
    const unsubSignal = onAppEvent((msg) => {
      if (msg.type === 'signal_connected') {
        waitingForDaemon = true;
        connecting = false;
      } else if (msg.type === 'daemon_disconnected') {
        waitingForDaemon = true;
        authReady = false;
      }
    });
    const unsubAuthSuccess = transport.onMessage((msg) => {
      if (msg.type === 'auth_result' && msg.success) {
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
      unsubAuthSuccess();
      disconnect();
      document.removeEventListener('click', handleClickOutside);
    };
  });

  async function waitForOpen(timeout = 10000): Promise<boolean> {
    const start = Date.now();
    while (!isConnected()) {
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
        await connect(signalUrl, pairing.pairingCode);
        setStoredPairingCode(pairing.pairingCode);
        setStoredSecret(pairing.setupSecret);
        if (await waitForOpen()) {
          authenticate(pairing.setupSecret);
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
        await connect(signalUrl, storedCode);
        if (await waitForOpen()) {
          authenticate(storedToken);
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
      await connect(signalUrl, code);
      setStoredPairingCode(code);
      setStoredToken(secret);
      if (await waitForOpen()) {
        authenticate(secret);
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

<main>
  {#if currentView !== 'detail'}
    <header>
      <h1 class="brand">Kite</h1>
      <div class="header-right">
      <ConnectionStatus {getPeerConnection} />
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
      </div>
    </header>
  {/if}

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
    <div class="view-container">
      {#if currentView === 'list'}
        <SessionList onselect={openSession} />
      {:else if selectedSessionId}
        <SessionDetail sessionId={selectedSessionId} onback={goBack} />
      {/if}
    </div>
  {/if}
</main>

<style>
  main { display: flex; flex-direction: column; height: 100dvh; }
  header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 0.2rem 0.5rem; padding-top: calc(0.2rem + env(safe-area-inset-top, 0px));
    background: var(--card-bg); flex-shrink: 0;
    border-bottom: none; position: relative;
    transition: background-color 0.2s;
  }
  header::after {
    content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 1px;
    background: linear-gradient(90deg, transparent, var(--border-glow), var(--accent), var(--border-glow), transparent);
    opacity: 0.6;
  }
  .brand {
    font-family: 'Orbitron', sans-serif; font-size: 0.85rem; font-weight: 700;
    color: var(--accent); letter-spacing: 0.05em;
    padding-left: 0.25rem;
  }

  .header-right { display: flex; align-items: center; gap: 0.4rem; }

  /* Theme picker */
  .theme-picker { position: relative; }
  .theme-toggle {
    background: none; border: 1px solid var(--border); border-radius: 6px;
    color: var(--text-secondary); padding: 0.2rem; display: flex; align-items: center;
    min-width: 36px; min-height: 36px; justify-content: center;
  }
  .theme-toggle:hover { border-color: var(--accent); color: var(--accent); }
  .theme-menu {
    position: absolute; top: 100%; right: 0; margin-top: 0.4rem;
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.25rem; z-index: 30; min-width: 160px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  }
  .theme-item {
    display: flex; width: 100%; text-align: left; padding: 0.5rem 0.75rem;
    background: none; border: none; border-radius: 6px;
    color: var(--fg); font-size: 0.85rem; min-height: 44px;
    align-items: center;
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
