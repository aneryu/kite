import type { ServerMessage } from './types';
import type { Transport, TransportState, MessageHandler, StateHandler } from './transport';

export class LanWebSocket implements Transport {
  readonly name = 'lan-ws';
  readonly priority = 1;

  private ws: WebSocket | null = null;
  private msgHandlers: MessageHandler[] = [];
  private stateHandlers: StateHandler[] = [];
  private lanIp: string;
  private lanPort: number;
  private token: string | null = null;
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;

  constructor(lanIp: string, lanPort: number) {
    this.lanIp = lanIp;
    this.lanPort = lanPort;
  }

  async connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const url = `ws://${this.lanIp}:${this.lanPort}/ws`;
      const timeout = setTimeout(() => {
        reject(new Error('LAN WS connect timeout'));
      }, 3000);

      try {
        this.ws = new WebSocket(url);
      } catch {
        clearTimeout(timeout);
        reject(new Error('LAN WS failed to create'));
        return;
      }

      this.ws.onopen = () => {
        clearTimeout(timeout);
        console.log('[LAN-WS] Connected');
        this.reconnectDelay = 2000;
        this.notifyState('open');
        if (this.token) {
          this.send(JSON.stringify({ type: 'auth', token: this.token }));
        }
        resolve();
      };

      this.ws.onmessage = (ev) => {
        try {
          const msg: ServerMessage = JSON.parse(ev.data);
          if (msg.type === 'pong') return;
          this.msgHandlers.forEach((h) => h(msg));
        } catch (e) {
          console.error('[LAN-WS] parse error:', e);
        }
      };

      this.ws.onclose = () => {
        console.log('[LAN-WS] Closed');
        this.notifyState('closed');
        this.scheduleReconnect();
      };

      this.ws.onerror = () => {
        clearTimeout(timeout);
        this.notifyState('closed');
        reject(new Error('LAN WS connection error'));
      };
    });
  }

  setToken(token: string): void {
    this.token = token;
    if (this.isOpen()) {
      this.send(JSON.stringify({ type: 'auth', token }));
    }
  }

  send(data: string): void {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    }
  }

  isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
  }

  onMessage(handler: MessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  onStateChange(handler: StateHandler): () => void {
    this.stateHandlers.push(handler);
    return () => { this.stateHandlers = this.stateHandlers.filter((h) => h !== handler); };
  }

  private notifyState(state: TransportState): void {
    this.stateHandlers.forEach((h) => h(state));
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => {
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
      });
    }, this.reconnectDelay);
  }
}
