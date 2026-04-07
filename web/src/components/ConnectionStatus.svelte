<script lang="ts">
  import { onMount } from 'svelte';
  import { onConnectionInfo, type ConnectionInfo, type ConnState } from '../lib/connection';

  let info = $state<ConnectionInfo>({ signal: 'disconnected', webrtc: 'disconnected', lanWs: 'disconnected', iceServers: [], gatheredCandidateTypes: [] });
  let expanded = $state(false);
  let candidateType = $state<string | null>(null);
  let activeServerUrl = $state<string | null>(null);

  let { getPeerConnection = () => null as RTCPeerConnection | null }: { getPeerConnection?: () => RTCPeerConnection | null } = $props();

  onMount(() => {
    const unsub = onConnectionInfo((i) => { info = i; });

    const statsInterval = setInterval(async () => {
      const pc = getPeerConnection();
      if (!pc) { candidateType = null; activeServerUrl = null; return; }
      try {
        const stats = await pc.getStats();
        stats.forEach((report) => {
          if (report.type === 'candidate-pair' && (report.state === 'succeeded' || (report.state === 'in-progress' && report.nominated))) {
            const local = stats.get(report.localCandidateId);
            if (local) {
              candidateType = local.candidateType;
              activeServerUrl = local.url || null;
            }
          }
        });
      } catch { /* ignore */ }
    }, 3000);

    const handleClickOutside = (e: MouseEvent) => {
      if (expanded && !(e.target as HTMLElement).closest('.conn-status')) {
        expanded = false;
      }
    };
    document.addEventListener('click', handleClickOutside);

    return () => {
      unsub();
      clearInterval(statsInterval);
      document.removeEventListener('click', handleClickOutside);
    };
  });

  function candidateTypeLabel(ct: string): string {
    if (ct === 'relay') return 'TURN';
    if (ct === 'srflx') return 'STUN';
    if (ct === 'host') return 'LAN';
    if (ct === 'prflx') return 'P2P';
    return ct;
  }

  // Normalize ICE server string to "host:port" for comparison
  // "stun:relay.fun.dev:3478" → "relay.fun.dev:3478"
  // "stun:relay.fun.dev:3478" from getStats url field is already like "stun:relay.fun.dev:3478"
  function normalizeAddr(s: string): string {
    return s.replace(/^(stun|turn|stuns|turns):\/?\/?/, '').replace(/\?.*$/, '');
  }

  function isActiveServer(server: string): boolean {
    if (!activeServerUrl || info.webrtc !== 'connected') return false;
    return normalizeAddr(server) === normalizeAddr(activeServerUrl);
  }

  function serverType(server: string): string {
    if (server.startsWith('turn:') || server.startsWith('turns:')) return 'TURN';
    return 'STUN';
  }

  function serverAddr(server: string): string {
    return normalizeAddr(server);
  }

  function overallState(): { color: string; label: string } {
    if (info.webrtc === 'connected') {
      const typeLabel = candidateType ? candidateTypeLabel(candidateType) : 'WebRTC';
      return { color: 'var(--conn-green)', label: typeLabel };
    }
    if (info.webrtc === 'connecting') return { color: 'var(--conn-yellow)', label: '连接中' };
    if (info.signal === 'connected') return { color: 'var(--conn-yellow)', label: '等待' };
    if (info.signal === 'connecting') return { color: 'var(--conn-red)', label: '重连' };
    return { color: 'var(--conn-red)', label: '断开' };
  }

  function stateLabel(s: ConnState): string {
    return s === 'connected' ? '已连接' : s === 'connecting' ? '连接中' : '未连接';
  }

  function stateColor(s: ConnState): string {
    return s === 'connected' ? 'var(--conn-green)' : s === 'connecting' ? 'var(--conn-yellow)' : 'var(--conn-dim)';
  }
</script>

<div class="conn-status">
  <button class="indicator" onclick={() => expanded = !expanded} aria-label="Connection status">
    <span class="dot" class:pulse={info.webrtc === 'connecting' || info.signal === 'connecting'} style="background:{overallState().color}"></span>
    <span class="label">{overallState().label}</span>
  </button>

  {#if expanded}
    <div class="panel">
      <div class="row">
        <span class="row-label">Signal</span>
        <span class="row-dot" style="background:{stateColor(info.signal)}"></span>
        <span class="row-value">{stateLabel(info.signal)}</span>
      </div>
      <div class="row">
        <span class="row-label">WebRTC</span>
        <span class="row-dot" style="background:{stateColor(info.webrtc)}"></span>
        <span class="row-value">
          {stateLabel(info.webrtc)}
          {#if info.webrtc === 'connected' && candidateType}
            <span class="tag">{candidateTypeLabel(candidateType)}</span>
          {/if}
        </span>
      </div>
      <div class="row">
        <span class="row-label">LAN WS</span>
        <span class="row-dot" style="background:{stateColor(info.lanWs)}"></span>
        <span class="row-value">{stateLabel(info.lanWs)}</span>
      </div>

      {#if info.iceServers.length > 0}
        <div class="section-label">ICE Servers</div>
        {#each info.iceServers as server}
          {@const active = isActiveServer(server)}
          <div class="ice-row" class:active>
            <span class="ice-dot" style="background:{active ? 'var(--conn-green)' : 'var(--conn-dim)'}"></span>
            <span class="ice-type">{serverType(server)}</span>
            <span class="ice-addr">{serverAddr(server)}</span>
          </div>
        {/each}
      {/if}
    </div>
  {/if}
</div>

<style>
  .conn-status {
    position: relative;
    --conn-green: #4caf50;
    --conn-yellow: #ffc107;
    --conn-red: #ef5350;
    --conn-dim: #555;
  }
  .indicator {
    display: flex; align-items: center; gap: 0.35rem;
    background: none; border: 1px solid var(--border); border-radius: 6px;
    color: var(--text-secondary); padding: 0.2rem 0.5rem;
    font-size: 0.75rem; min-height: 36px; cursor: pointer;
  }
  .indicator:hover { border-color: var(--accent); color: var(--accent); }

  .dot {
    width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0;
  }
  .dot.pulse { animation: blink 1.2s ease-in-out infinite; }

  .label { white-space: nowrap; }

  .panel {
    position: absolute; top: 100%; right: 0; margin-top: 0.4rem;
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 0.6rem 0.75rem; z-index: 30; min-width: 240px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  }

  .row {
    display: flex; align-items: center; gap: 0.4rem;
    padding: 0.25rem 0; font-size: 0.8rem;
  }
  .row-label { width: 56px; color: var(--text-muted); flex-shrink: 0; }
  .row-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .row-value { color: var(--fg); }

  .tag {
    display: inline-block; font-size: 0.65rem; padding: 0.1rem 0.35rem;
    border-radius: 4px; background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent); font-weight: 600; margin-left: 0.3rem;
  }

  .section-label {
    margin-top: 0.5rem; padding-top: 0.4rem;
    border-top: 1px solid var(--border);
    color: var(--text-muted); font-size: 0.7rem; text-transform: uppercase;
    letter-spacing: 0.05em; margin-bottom: 0.2rem;
  }

  .ice-row {
    display: flex; align-items: center; gap: 0.4rem;
    padding: 0.2rem 0; font-size: 0.75rem;
  }
  .ice-row.active .ice-addr { color: var(--fg); }
  .ice-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
  .ice-type {
    font-size: 0.6rem; font-weight: 700; min-width: 32px;
    color: var(--text-muted);
  }
  .ice-addr {
    font-family: monospace; font-size: 0.72rem; color: var(--text-muted);
    word-break: break-all;
  }

  @keyframes blink {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.3; }
  }
</style>
