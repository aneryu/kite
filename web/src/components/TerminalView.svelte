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
  let themeObserver: MutationObserver | null = null;

  function readCssTheme(): { background: string; foreground: string; cursor: string } {
    const style = getComputedStyle(document.documentElement);
    return {
      background: style.getPropertyValue('--bg').trim() || '#0a0a0a',
      foreground: style.getPropertyValue('--fg').trim() || '#e0e0e0',
      cursor: style.getPropertyValue('--accent').trim() || '#4fc3f7',
    };
  }

  onMount(async () => {
    const cssTheme = readCssTheme();
    // 12px on phones (<=480px), 14px on tablets/desktop
    const isMobile = window.innerWidth <= 480;
    terminal = new Terminal({
      fontSize: isMobile ? 12 : 14,
      fontFamily: "'Hack Nerd Font Mono', 'Fira Code', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace",
      theme: cssTheme,
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

    let snapshotRequested = false;
    function doFitAndResize() {
      const rect = containerEl.getBoundingClientRect();
      console.log('[TerminalView] doFitAndResize: container rect=', rect.width, 'x', rect.height);
      fitAddon.fit();
      console.log('[TerminalView] after fit: cols=', terminal.cols, 'rows=', terminal.rows);
      if (terminal.cols === 0 || terminal.rows === 0) {
        console.log('[TerminalView] cols/rows is 0, retrying next frame');
        requestAnimationFrame(doFitAndResize);
        return;
      }
      rtc.sendResize(terminal.cols, terminal.rows, sessionId);
      if (!snapshotRequested) {
        snapshotRequested = true;
        rtc.requestSnapshot(sessionId);
      }
    }
    resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      console.log('[TerminalView] ResizeObserver fired: contentRect=', entry.contentRect.width, 'x', entry.contentRect.height);
      doFitAndResize();
    });
    resizeObserver.observe(containerEl);

    // Watch for theme changes (data-theme attribute on <html>)
    themeObserver = new MutationObserver(() => {
      terminal.options.theme = readCssTheme();
    });
    themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  });

  onDestroy(() => {
    unsubscribe?.();
    resizeObserver?.disconnect();
    themeObserver?.disconnect();
    terminal?.dispose();
  });
</script>

<div class="terminal-container" bind:this={containerEl}></div>

<style>
  .terminal-container { flex: 1; overflow: hidden; }
</style>
