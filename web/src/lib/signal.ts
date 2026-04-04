export interface SignalMessage {
  type: string;
  sdp?: string;
  sdp_type?: string;
  candidate?: string;
  mid?: string;
  error?: string;
  [key: string]: unknown;
}

export type SignalMessageHandler = (msg: SignalMessage) => void;

export class SignalClient {
  private ws: WebSocket | null = null;
  private handlers: SignalMessageHandler[] = [];
  private reconnectTimer: number | null = null;
  private url: string;
  private pairingCode: string;

  constructor(url: string, pairingCode: string) {
    this.url = url;
    this.pairingCode = pairingCode;
  }

  /** Connect to signal server. Returns promise that resolves on open. */
  connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws?.readyState === WebSocket.OPEN) { resolve(); return; }
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => {
        this.send({ type: 'join', pairing_code: this.pairingCode });
        resolve();
      };
      this.ws.onmessage = (ev) => {
        try {
          const msg: SignalMessage = JSON.parse(ev.data);
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
      this.connect();
    }, 2000);
  }

  /** Subscribe to messages. Returns unsubscribe function. */
  onMessage(handler: SignalMessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  /** Send SDP offer to daemon via signal server */
  sendSdpOffer(sdp: string, sdpType: string): void {
    this.send({ type: 'sdp_offer', sdp, sdp_type: sdpType });
  }

  /** Send ICE candidate to daemon via signal server */
  sendIceCandidate(candidate: string, mid: string): void {
    this.send({ type: 'ice_candidate', candidate, mid });
  }

  private send(msg: Record<string, unknown>) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(msg));
    }
  }

  /** Disconnect and clean up */
  disconnect() {
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.ws?.close();
    this.ws = null;
  }
}
