import type { ServerMessage } from './types';

export type TransportState = 'connecting' | 'open' | 'closed';
export type MessageHandler = (msg: ServerMessage) => void;
export type StateHandler = (state: TransportState) => void;

export interface Transport {
  readonly name: string;
  readonly priority: number;
  connect(): Promise<void>;
  send(data: string): void;
  isOpen(): boolean;
  disconnect(): void;
  onMessage(handler: MessageHandler): () => void;
  onStateChange(handler: StateHandler): () => void;
}

export class TransportManager {
  private transports: Transport[] = [];
  private msgHandlers: MessageHandler[] = [];
  private activeTransportName: string | null = null;
  private unsubscribers: (() => void)[] = [];

  register(transport: Transport): void {
    this.transports.push(transport);
    this.transports.sort((a, b) => a.priority - b.priority);

    const unsubMsg = transport.onMessage((msg) => {
      if (transport.name === this.activeTransportName) {
        this.msgHandlers.forEach((h) => h(msg));
      }
    });

    const unsubState = transport.onStateChange(() => {
      this.updateActiveTransport();
    });

    this.unsubscribers.push(unsubMsg, unsubState);
  }

  async connectAll(): Promise<void> {
    await Promise.allSettled(this.transports.map((t) => t.connect()));
  }

  send(msg: Record<string, unknown>): void {
    const data = JSON.stringify(msg);
    const active = this.getActiveTransport();
    if (active) {
      active.send(data);
    } else {
      console.warn('[Transport] send DROPPED (no transport open):', msg.type);
    }
  }

  onMessage(handler: MessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  isConnected(): boolean {
    return this.transports.some((t) => t.isOpen());
  }

  activeTransport(): string | null {
    return this.activeTransportName;
  }

  disconnect(): void {
    this.unsubscribers.forEach((u) => u());
    this.unsubscribers = [];
    this.transports.forEach((t) => t.disconnect());
    this.transports = [];
    this.activeTransportName = null;
  }

  requestSync(): void {
    this.send({ type: 'request_sync' });
  }

  private getActiveTransport(): Transport | null {
    for (const t of this.transports) {
      if (t.isOpen()) return t;
    }
    return null;
  }

  private updateActiveTransport(): void {
    const best = this.getActiveTransport();
    const newName = best?.name ?? null;
    if (newName !== this.activeTransportName) {
      const prev = this.activeTransportName;
      this.activeTransportName = newName;
      console.log(`[Transport] Active: ${prev} → ${newName}`);
      if (newName) {
        this.requestSync();
      }
    }
  }
}
