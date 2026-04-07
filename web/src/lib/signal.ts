export interface SignalMessage {
  type: string;
  member_id?: string;
  role?: string;
  from?: string;
  to?: string;
  payload?: Record<string, unknown>;
  members?: Array<{ id: string; role: string }>;
  error?: string;
  [key: string]: unknown;
}

export type SignalMessageHandler = (msg: SignalMessage) => void;

export type SignalState = 'connecting' | 'open' | 'closed';
export type SignalStateHandler = (state: SignalState) => void;

export class SignalClient {
  private ws: WebSocket | null = null;
  private handlers: SignalMessageHandler[] = [];
  private stateHandlers: SignalStateHandler[] = [];
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;
  private maxReconnectDelay = 30000;
  private url: string;
  private pairingCode: string;
  private role: string;
  public memberID: string = '';

  // Heartbeat state
  private pingInterval: number | null = null;
  private pongTimeout: number | null = null;
  private readonly PING_INTERVAL = 15_000;
  private readonly PONG_TIMEOUT = 30_000;

  // Buffered messages to send after reconnect
  private pendingSends: string[] = [];

  constructor(url: string, pairingCode: string, role: string = 'browser') {
    this.url = url;
    this.pairingCode = pairingCode;
    this.role = role;
  }

  onStateChange(handler: SignalStateHandler): () => void {
    this.stateHandlers.push(handler);
    return () => { this.stateHandlers = this.stateHandlers.filter((h) => h !== handler); };
  }

  private notifyState(state: SignalState) {
    this.stateHandlers.forEach((h) => h(state));
  }

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws?.readyState === WebSocket.OPEN) { resolve(); return; }
      this.notifyState('connecting');
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => {
        this.send({ type: 'join', pairing_code: this.pairingCode, role: this.role });
        this.reconnectDelay = 2000;
        this.startHeartbeat();
        this.flushPending();
        this.notifyState('open');
        resolve();
      };
      this.ws.onmessage = (ev) => {
        try {
          const msg: SignalMessage = JSON.parse(ev.data);
          // Any message from server counts as "alive" — reset pong timeout
          this.resetPongTimeout();
          if (msg.type === 'joined' && msg.member_id) {
            this.memberID = msg.member_id;
          }
          this.handlers.forEach((h) => h(msg));
        } catch {}
      };
      this.ws.onclose = () => {
        this.stopHeartbeat();
        this.notifyState('closed');
        this.scheduleReconnect();
      };
      this.ws.onerror = () => {
        this.ws?.close();
        reject(new Error('WebSocket error'));
      };
    });
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null;
      this.connect().catch(() => {
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
      });
    }, this.reconnectDelay);
  }

  /** Force an immediate reconnect attempt (used by recovery logic). */
  forceReconnect(): void {
    if (this.ws?.readyState === WebSocket.OPEN) return;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.connect().catch(() => {});
  }

  isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  onMessage(handler: SignalMessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  relay(to: string, payload: Record<string, unknown>): void {
    this.sendOrBuffer({ type: 'relay', to, payload });
  }

  broadcast(payload: Record<string, unknown>): void {
    this.sendOrBuffer({ type: 'broadcast', payload });
  }

  /** Send immediately if connected, otherwise buffer for after reconnect. */
  private sendOrBuffer(msg: Record<string, unknown>) {
    const json = JSON.stringify(msg);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(json);
    } else {
      this.pendingSends.push(json);
    }
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  private flushPending() {
    const msgs = this.pendingSends.splice(0);
    for (const json of msgs) {
      if (this.ws?.readyState === WebSocket.OPEN) {
        this.ws.send(json);
      }
    }
  }

  // --- Heartbeat ---

  private startHeartbeat() {
    this.stopHeartbeat();
    this.pingInterval = window.setInterval(() => {
      this.send({ type: 'ping' });
    }, this.PING_INTERVAL);
    this.resetPongTimeout();
  }

  private stopHeartbeat() {
    if (this.pingInterval !== null) { clearInterval(this.pingInterval); this.pingInterval = null; }
    if (this.pongTimeout !== null) { clearTimeout(this.pongTimeout); this.pongTimeout = null; }
  }

  private resetPongTimeout() {
    if (this.pongTimeout !== null) clearTimeout(this.pongTimeout);
    this.pongTimeout = window.setTimeout(() => {
      console.warn('[Signal] No response in 30s, forcing reconnect');
      this.ws?.close();
    }, this.PONG_TIMEOUT);
  }

  disconnect() {
    this.stopHeartbeat();
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
    this.pendingSends = [];
    this.notifyState('closed');
  }
}
