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
  private daemonMemberID: string | null = null;
  private stunServer: string = 'stun:stun.l.google.com:19302';
  private storedToken: string | null = null;

  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    if (stunServer) this.stunServer = stunServer;
    this.signal = new SignalClient(signalUrl, pairingCode, 'browser');

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'joined':
          // Check if daemon is already in the topic
          this.daemonMemberID = null;
          if (msg.members) {
            const daemon = msg.members.find((m) => m.role === 'daemon');
            if (daemon) {
              this.daemonMemberID = daemon.id;
              this.startWebRTC();
            }
            // else: no daemon yet, wait for member_joined
          }
          this.handlers.forEach((h) => h({ type: 'signal_connected' }));
          break;
        case 'member_joined':
          if (msg.role === 'daemon' && msg.member_id) {
            this.daemonMemberID = msg.member_id;
            this.startWebRTC();
          }
          break;
        case 'member_left':
          if (msg.member_id === this.daemonMemberID) {
            this.handlePeerLeft();
            this.daemonMemberID = null;
            this.handlers.forEach((h) => h({ type: 'daemon_disconnected' }));
          }
          break;
        case 'relay':
          if (msg.payload) {
            this.handleRelayedMessage(msg.payload);
          }
          break;
        case 'error':
          console.error('[RTC] Signal error:', msg.error);
          break;
      }
    });

    await this.signal.connect();
  }

  onMessage(handler: MessageHandler): () => void {
    this.handlers.push(handler);
    return () => { this.handlers = this.handlers.filter((h) => h !== handler); };
  }

  authenticate(token: string): void {
    this.storedToken = token;
    this.authenticated = true;
    this.sendRaw({ type: 'auth', token });
  }

  sendTerminalInput(data: string, sessionId: number): void {
    this.sendRaw({ type: 'terminal_input', data, session_id: sessionId });
  }

  sendResize(cols: number, rows: number, sessionId: number): void {
    this.sendRaw({ type: 'resize', cols, rows, session_id: sessionId });
  }

  requestSnapshot(sessionId: number): void {
    this.sendRaw({ type: 'request_snapshot', session_id: sessionId });
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
    this.daemonMemberID = null;
  }

  // --- Private ---

  private startWebRTC(): void {
    // Clean up any existing connection
    this.stopPing();
    this.dc?.close();
    this.pc?.close();
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    const iceServers: RTCIceServer[] = [{ urls: this.stunServer }];
    this.pc = new RTCPeerConnection({ iceServers });
    this.dc = this.pc.createDataChannel('kite', { ordered: true });

    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
      // Auto re-authenticate if we have a stored token
      if (this.storedToken) {
        this.sendRaw({ type: 'auth', token: this.storedToken });
      }
    };

    this.dc.onmessage = (ev) => {
      try {
        const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
        const msg: ServerMessage = JSON.parse(raw);
        if (msg.type === 'pong') return;
        this.handlers.forEach((h) => h(msg));
      } catch (e) {
        console.error('[RTC] DC message parse error:', e);
      }
    };

    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
    };

    this.pc.onicecandidate = (ev) => {
      if (ev.candidate && this.signal && this.daemonMemberID) {
        this.signal.relay(this.daemonMemberID, {
          type: 'ice_candidate',
          candidate: ev.candidate.candidate,
          mid: ev.candidate.sdpMid || '',
        });
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'disconnected' || state === 'failed') {
        this.handlePeerLeft();
      }
    };

    this.pc.createOffer()
      .then((offer) => this.pc!.setLocalDescription(offer))
      .then(() => {
        if (this.pc?.localDescription && this.signal && this.daemonMemberID) {
          this.signal.relay(this.daemonMemberID, {
            type: 'sdp_offer',
            sdp: this.pc.localDescription.sdp,
            sdp_type: this.pc.localDescription.type,
          });
        }
      })
      .catch((err) => console.error('[RTC] Offer error:', err));
  }

  private handleRelayedMessage(payload: Record<string, unknown>): void {
    const type = payload.type as string;
    if (type === 'sdp_answer') {
      this.handleSdpAnswer(payload.sdp as string, payload.sdp_type as RTCSdpType);
    } else if (type === 'ice_candidate') {
      this.handleRemoteCandidate(payload.candidate as string, payload.mid as string);
    }
  }

  private async handleSdpAnswer(sdp: string, sdpType: RTCSdpType): Promise<void> {
    if (!this.pc) return;
    try {
      await this.pc.setRemoteDescription(new RTCSessionDescription({ sdp, type: sdpType }));
      this.remoteDescriptionSet = true;
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
    }
  }
}

export const rtc = new RtcManager();
