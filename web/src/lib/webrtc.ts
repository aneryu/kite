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
  private pendingCandidates: { candidate: string; mid: string }[] = [];
  private remoteDescriptionSet = false;

  /** Connect to signaling server and wait for peer_joined to start WebRTC */
  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    this.signal = new SignalClient(signalUrl, pairingCode);

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'joined':
          // Signal server confirmed we joined the room — start WebRTC handshake
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
        const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
        console.log('[RTC] DC recv:', raw.substring(0, 200));
        const msg: ServerMessage = JSON.parse(raw);
        if (msg.type === 'pong') return;
        console.log('[RTC] Dispatching to', this.handlers.length, 'handlers, type:', msg.type);
        this.handlers.forEach((h) => h(msg));
      } catch (e) {
        console.error('[RTC] DC message parse error:', e, 'raw:', ev.data);
      }
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
          this.signal.sendSdpOffer(this.pc.localDescription.sdp, this.pc.localDescription.type);
        }
      })
      .catch((err) => console.error('[RTC] Offer error:', err));
  }

  private async handleSdpAnswer(sdp: string, sdpType: RTCSdpType): Promise<void> {
    if (!this.pc) return;
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription({ sdp, type: sdpType }));
      console.log('[RTC] Remote description set');
      this.remoteDescriptionSet = true;
      // Flush any ICE candidates that arrived before the answer
      for (const c of this.pendingCandidates) {
        await this.pc.addIceCandidate(new RTCIceCandidate({ candidate: c.candidate, sdpMid: c.mid }));
      }
      this.pendingCandidates = [];
    } catch (err) {
      console.error('[RTC] setRemoteDescription error:', err);
    }
  }

  private async handleRemoteCandidate(candidate: string, mid: string): Promise<void> {
    if (!this.pc) return;
    if (!this.remoteDescriptionSet) {
      // Queue until remote description is set
      this.pendingCandidates.push({ candidate, mid });
      return;
    }
    try {
      await this.pc.addIceCandidate(new RTCIceCandidate({ candidate, sdpMid: mid }));
    } catch (err) {
      console.error('[RTC] addIceCandidate error:', err);
    }
  }

  private handlePeerLeft(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];
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
