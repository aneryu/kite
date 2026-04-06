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

  // Recovery state
  private recovering = false;
  private recoveryTimeout: number | null = null;
  private visibilityHandler: (() => void) | null = null;

  async connect(signalUrl: string, pairingCode: string, stunServer?: string): Promise<void> {
    if (stunServer) this.stunServer = stunServer;
    this.signal = new SignalClient(signalUrl, pairingCode, 'browser');

    this.signal.onMessage((msg) => {
      switch (msg.type) {
        case 'joined':
          this.daemonMemberID = null;
          if (msg.members) {
            const daemon = msg.members.find((m) => m.role === 'daemon');
            if (daemon) {
              this.daemonMemberID = daemon.id;
              if (!this.pc) {
                this.startWebRTC();
              }
              // If we're recovering and signal just reconnected, re-attempt ICE restart
              if (this.recovering && this.pc) {
                this.attemptIceRestart();
              }
            }
          }
          this.handlers.forEach((h) => h({ type: 'signal_connected' }));
          break;
        case 'member_joined':
          if (msg.role === 'daemon' && msg.member_id) {
            this.daemonMemberID = msg.member_id;
            if (this.recovering) {
              // Daemon came back — do full rebuild as part of recovery
              this.cancelRecovery();
              this.fullRebuild();
            } else if (!this.pc) {
              this.startWebRTC();
            }
          }
          break;
        case 'member_left':
          if (msg.member_id === this.daemonMemberID) {
            this.cancelRecovery();
            this.teardownPeer();
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
    this.installVisibilityHandler();
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
    this.cancelRecovery();
    this.removeVisibilityHandler();
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

  // --- Parallel Recovery ---

  private startRecovery(): void {
    if (this.recovering) return;
    this.recovering = true;
    console.log('[RTC] Starting parallel recovery');

    // Path 1: Probe existing DC — send ping + request_sync
    if (this.dc?.readyState === 'open') {
      this.sendRaw({ type: 'ping' });
      this.sendRaw({ type: 'request_sync' });
    }

    // Path 2: ICE restart (needs signal to be connected)
    if (this.pc && this.signal?.isConnected() && this.daemonMemberID) {
      this.attemptIceRestart();
    }

    // Path 3: Ensure signal is alive (triggers re-join which leads to ICE restart)
    if (this.signal && !this.signal.isConnected()) {
      this.signal.forceReconnect();
    }

    // Fallback timeout: 15s → full rebuild
    this.recoveryTimeout = window.setTimeout(() => {
      if (this.recovering) {
        console.log('[RTC] Recovery timeout, falling back to full rebuild');
        this.cancelRecovery();
        this.fullRebuild();
      }
    }, 15_000);
  }

  private cancelRecovery(): void {
    this.recovering = false;
    if (this.recoveryTimeout !== null) {
      clearTimeout(this.recoveryTimeout);
      this.recoveryTimeout = null;
    }
  }

  private onRecoverySuccess(): void {
    if (!this.recovering) return;
    console.log('[RTC] Recovery succeeded');
    this.cancelRecovery();
    // Request full state sync
    this.sendRaw({ type: 'request_sync' });
  }

  private attemptIceRestart(): void {
    if (!this.pc || !this.signal || !this.daemonMemberID) return;
    console.log('[RTC] Attempting ICE restart');

    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    this.pc.createOffer({ iceRestart: true })
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
      .catch((err) => console.error('[RTC] ICE restart offer error:', err));
  }

  private fullRebuild(): void {
    console.log('[RTC] Full rebuild');
    this.teardownPeer();
    if (this.daemonMemberID) {
      this.startWebRTC();
    }
  }

  private teardownPeer(): void {
    this.stopPing();
    this.dc?.close();
    this.dc = null;
    this.pc?.close();
    this.pc = null;
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];
    this.authenticated = false;
    this.handlers.forEach((h) => h({ type: 'disconnected' }));
  }

  // --- Visibility ---

  private installVisibilityHandler(): void {
    this.removeVisibilityHandler();
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        if (this.dc?.readyState === 'open') {
          this.sendRaw({ type: 'request_sync' });
        } else if (this.pc) {
          this.startRecovery();
        }
      }
    };
    document.addEventListener('visibilitychange', this.visibilityHandler);
  }

  private removeVisibilityHandler(): void {
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler);
      this.visibilityHandler = null;
    }
  }

  // --- WebRTC Setup ---

  private startWebRTC(): void {
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
      if (this.recovering) {
        this.onRecoverySuccess();
      } else if (this.storedToken) {
        this.sendRaw({ type: 'auth', token: this.storedToken });
      }
    };

    this.dc.onmessage = (ev) => {
      try {
        const raw = typeof ev.data === 'string' ? ev.data : new TextDecoder().decode(ev.data);
        const msg: ServerMessage = JSON.parse(raw);
        if (msg.type === 'pong') {
          if (this.recovering) this.onRecoverySuccess();
          return;
        }
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
        this.startRecovery();
      } else if (state === 'connected' && this.recovering) {
        // ICE restart succeeded at transport level, wait for DC to re-open
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
      console.warn('[RTC] sendRaw DROPPED (dc not open):', msg.type);
    }
  }
}

export const rtc = new RtcManager();
