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

export class SignalClient {
  private ws: WebSocket | null = null;
  private handlers: SignalMessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private reconnectDelay = 2000;
  private maxReconnectDelay = 30000;
  private url: string;
  private pairingCode: string;
  private role: string;
  public memberID: string = '';

  constructor(url: string, pairingCode: string, role: string = 'browser') {
    this.url = url;
    this.pairingCode = pairingCode;
    this.role = role;
  }

  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws?.readyState === WebSocket.OPEN) { resolve(); return; }
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => {
        this.send({ type: 'join', pairing_code: this.pairingCode, role: this.role });
        this.reconnectDelay = 2000; // reset backoff
        resolve();
      };
      this.ws.onmessage = (ev) => {
        try {
          const msg: SignalMessage = JSON.parse(ev.data);
          if (msg.type === 'joined' && msg.member_id) {
            this.memberID = msg.member_id;
          }
          this.handlers.forEach((h) => h(msg));
        } catch {}
      };
      this.ws.onclose = () => this.scheduleReconnect();
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
        // Increase backoff on failure
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay);
      });
    }, this.reconnectDelay);
  }

  onMessage(handler: SignalMessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  /** Send a relay message to a specific member */
  relay(to: string, payload: Record<string, unknown>): void {
    this.send({ type: 'relay', to, payload });
  }

  /** Send a broadcast message to all other members */
  broadcast(payload: Record<string, unknown>): void {
    this.send({ type: 'broadcast', payload });
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  disconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
  }
}
