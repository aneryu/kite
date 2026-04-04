import type { ServerMessage } from './types';

type MessageHandler = (msg: ServerMessage) => void;

export class WsManager {
  private ws: WebSocket | null = null;
  private handlers: MessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private url: string;

  constructor() {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.url = `${proto}//${location.host}/ws`;
  }

  connect() {
    if (this.ws?.readyState === WebSocket.OPEN) return;
    this.ws = new WebSocket(this.url);
    this.ws.onmessage = (ev) => {
      try {
        const msg: ServerMessage = JSON.parse(ev.data);
        this.handlers.forEach((h) => h(msg));
      } catch {}
    };
    this.ws.onclose = () => this.scheduleReconnect();
    this.ws.onerror = () => this.ws?.close();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 2000);
  }

  onMessage(handler: MessageHandler) {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  sendTerminalInput(data: string, sessionId: number) {
    this.send({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number) {
    this.send({ type: 'resize', cols, rows, session_id: sessionId });
  }

  sendPromptResponse(text: string, sessionId: number) {
    const payload = { type: 'prompt_response', text, session_id: sessionId };
    console.log('[WS] sendPromptResponse:', JSON.stringify(payload), 'readyState:', this.ws?.readyState);
    this.send(payload);
  }

  isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      const data = JSON.stringify(msg);
      console.log('[WS] send:', data);
      this.ws.send(data);
    } else {
      console.warn('[WS] send FAILED - not open, readyState:', this.ws?.readyState);
    }
  }

  disconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
  }
}

export const ws = new WsManager();
