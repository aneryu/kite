<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import { Unicode11Addon } from '@xterm/addon-unicode11';
  import '@xterm/xterm/css/xterm.css';
  import { rtc } from '../lib/webrtc';
  import type { ServerMessage } from '../lib/types';

  let { sessionId }: { sessionId: number } = $props();
  let containerEl: HTMLDivElement;
  let terminal: Terminal;
  let fitAddon: FitAddon;
  let unsubscribe: (() => void) | null = null;
  let resizeObserver: ResizeObserver | null = null;

  onMount(async () => {
    terminal = new Terminal({
      fontSize: 14,
      fontFamily: "'Hack Nerd Font Mono', 'Fira Code', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace",
      theme: { background: '#0a0a0a', foreground: '#e0e0e0', cursor: '#4fc3f7' },
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
    });
    fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    try {
      const unicode11 = new Unicode11Addon();
      terminal.loadAddon(unicode11);
      terminal.unicode.activeVersion = '11';
    } catch (e) {
      console.warn('Unicode11 addon failed to load:', e);
    }
    terminal.open(containerEl);
    fitAddon.fit();
    rtc.sendResize(terminal.cols, terminal.rows, sessionId);

    function base64ToBytes(b64: string): Uint8Array {
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    }

    unsubscribe = rtc.onMessage((msg: ServerMessage) => {
      if (msg.type === 'terminal_output' && msg.session_id === sessionId && msg.data) {
        terminal.write(base64ToBytes(msg.data));
      }
    });

    terminal.onData((data: string) => { rtc.sendTerminalInput(data, sessionId); });

    resizeObserver = new ResizeObserver(() => {
      fitAddon.fit();
      rtc.sendResize(terminal.cols, terminal.rows, sessionId);
    });
    resizeObserver.observe(containerEl);
  });

  onDestroy(() => {
    unsubscribe?.();
    resizeObserver?.disconnect();
    terminal?.dispose();
  });
</script>

<div class="terminal-container" bind:this={containerEl}></div>

<style>
  .terminal-container { flex: 1; overflow: hidden; }
</style>
