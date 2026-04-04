import type { ServerMessage } from './types';
import { SignalClient } from './signal';

type MessageHandler = (msg: ServerMessage) => void;

export class RtcManager {
  private pc: RTCPeerConnection | null = null;
  private dc: RTCDataChannel | null = null;
  private signal: SignalClient | null = null;
  private handlers: MessageHandler[] = [];
  private authenticated: boolean = false;
  private pingInterval: number | null = null;

  /** Connect to signaling server and wait for peer_joined to start WebRTC */
  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    this.signal = new SignalClient(signalUrl, pairingCode);

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'peer_joined':
          this.startWebRTC(stunServer);
          break;
        case 'sdp_answer':
          if (msg.sdp && msg.sdp_type) {
            this.handleSdpAnswer(msg.sdp, msg.sdp_type as RTCSdpType);
          }
          break;
        case 'ice_candidate':
          if (msg.candidate !== undefined && msg.mid !== undefined) {
            this.handleRemoteCandidate(msg.candidate, msg.mid);
          }
          break;
        case 'peer_left':
          this.handlePeerLeft();
          break;
        case 'error':
          console.error('[RTC] Signal error:', msg.error);
          break;
      }
    });

    this.signal.connect();
  }

  /** Subscribe to DataChannel messages. Returns unsubscribe. */
  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => {
      this.handlers = this.handlers.filter((h) => h !== handler);
    };
  }

  /** Send auth token via DataChannel */
  authenticate(token: string): void {
    this.authenticated = true;
    this.sendRaw({ type: 'auth', token });
  }

  /** Same API as WsManager */
  sendTerminalInput(data: string, sessionId: number): void {
    this.sendRaw({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number): void {
    this.sendRaw({ type: 'resize', cols, rows, session_id: sessionId });
  }

  sendPromptResponse(text: string, sessionId: number): void {
    this.sendRaw({ type: 'prompt_response', text, session_id: sessionId });
  }

  createSession(command?: string): void {
    this.sendRaw({ type: 'create_session', data: command || 'claude' });
  }

  deleteSession(sessionId: number): void {
    this.sendRaw({ type: 'delete_session', session_id: sessionId });
  }

  isOpen(): boolean {
    return this.dc?.readyState === 'open';
  }

  disconnect(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.signal?.disconnect();
    this.signal = null;
    this.authenticated = false;
  }

  // --- Private methods ---

  private startWebRTC(stunServer?: string): void {
    const iceServers: RTCIceServer[] = [
      { urls: stunServer || 'stun:stun.l.google.com:19302' },
    ];

    this.pc = new RTCPeerConnection({ iceServers });

    this.dc = this.pc.createDataChannel('kite', { ordered: true });

    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
    };

    this.dc.onmessage = (ev) => {
      try {
        const msg: ServerMessage = JSON.parse(ev.data);
        if (msg.type === 'pong') return;
        this.handlers.forEach((h) => h(msg));
      } catch {}
    };

    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
    };

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate && this.signal) {
        this.signal.sendIceCandidate(
          ev.candidate.candidate,
          ev.candidate.sdpMid || '',
        );
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'disconnected' || state === 'failed') {
        this.handlePeerLeft();
      }
    };

    this.pc
      .createOffer()
      .then((offer) => this.pc!.setLocalDescription(offer))
      .then(() => {
        if (this.pc?.localDescription && this.signal) {
          this.signal.sendSdpOffer(this.pc.localDescription.sdp);
        }
      })
      .catch((err) => console.error('[RTC] Offer error:', err));
  }

  private handleSdpAnswer(sdp: string, sdpType: RTCSdpType): void {
    if (!this.pc) return;
    this.pc
      .setRemoteDescription(new RTCSessionDescription({ sdp, type: sdpType }))
      .catch((err) => console.error('[RTC] setRemoteDescription error:', err));
  }

  private handleRemoteCandidate(candidate: string, mid: string): void {
    if (!this.pc) return;
    this.pc
      .addIceCandidate(new RTCIceCandidate({ candidate, sdpMid: mid }))
      .catch((err) => console.error('[RTC] addIceCandidate error:', err));
  }

  private handlePeerLeft(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.handlers.forEach((h) => h({ type: 'disconnected' }));
  }

  private startPing(): void {
    this.stopPing();
    this.pingInterval = window.setInterval(() => {
      this.sendRaw({ type: 'ping' });
    }, 10_000);
  }

  private stopPing(): void {
    if (this.pingInterval !== null) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private sendRaw(msg: Record<string, unknown>): void {
    if (this.dc?.readyState === 'open') {
      this.dc.send(JSON.stringify(msg));
    } else {
      console.warn('[RTC] sendRaw FAILED - DataChannel not open, readyState:', this.dc?.readyState);
    }
  }
}

export const rtc = new RtcManager();
