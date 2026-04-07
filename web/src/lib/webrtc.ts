import type { ServerMessage } from './types';
import type { Transport, TransportState, MessageHandler as TransportMessageHandler, StateHandler } from './transport';
import type { SignalClient } from './signal';

type AppEventHandler = (msg: ServerMessage) => void;

export class WebRtcTransport implements Transport {
  readonly name = 'webrtc';
  readonly priority = 2;

  private pc: RTCPeerConnection | null = null;
  private dc: RTCDataChannel | null = null;
  private signal: SignalClient | null = null;
  private appHandlers: AppEventHandler[] = [];
  private msgHandlers: TransportMessageHandler[] = [];
  private stateHandlers: StateHandler[] = [];
  private authenticated: boolean = false;
  private pingInterval: number | null = null;
  private pendingCandidates: { candidate: string; mid: string }[] = [];
  private remoteDescriptionSet = false;
  private daemonMemberID: string | null = null;
  private iceServers: string[] = [];
  private storedToken: string | null = null;

  // ICE candidate gathering state
  private gatheredTypes: Set<string> = new Set();
  private gatheringDone = false;

  // Recovery state
  private recovering = false;
  private recoveryTimeout: number | null = null;
  private visibilityHandler: (() => void) | null = null;

  private buildPcConfig(servers?: string[]): RTCConfiguration {
    const iceServers: RTCIceServer[] = (servers && servers.length > 0
      ? servers
      : ['stun:relay.fun.dev:3478']
    ).map((s) => {
      if (s.startsWith('turn:')) {
        const match = s.match(/^turn:([^:]+):([^@]+)@(.+)$/);
        if (match) {
          return { urls: `turn:${match[3]}`, username: match[1], credential: match[2] };
        }
      }
      return { urls: s };
    });
    return {
      iceServers,
      iceCandidatePoolSize: 4,
    };
  }

  // --- Transport interface methods ---

  async connect(): Promise<void> {
    // No-op: WebRTC connection is initiated by startWebRTC() called externally
    // after signal client is set up by connection.ts
  }

  send(data: string): void {
    if (this.dc?.readyState === 'open') {
      this.dc.send(data);
    } else {
      console.warn('[RTC] send DROPPED (dc not open)');
    }
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
    this.signal = null;
    this.authenticated = false;
    this.daemonMemberID = null;
  }

  onMessage(handler: TransportMessageHandler): () => void {
    this.msgHandlers.push(handler);
    return () => { this.msgHandlers = this.msgHandlers.filter((h) => h !== handler); };
  }

  onStateChange(handler: StateHandler): () => void {
    this.stateHandlers.push(handler);
    return () => { this.stateHandlers = this.stateHandlers.filter((h) => h !== handler); };
  }

  // --- App event handler (for signal_connected, daemon_disconnected, disconnected) ---

  onAppEvent(handler: AppEventHandler): () => void {
    this.appHandlers.push(handler);
    return () => { this.appHandlers = this.appHandlers.filter((h) => h !== handler); };
  }

  // --- Public setter methods (called by connection.ts) ---

  setSignal(signal: SignalClient): void {
    this.signal = signal;
  }

  setDaemonMemberID(id: string): void {
    this.daemonMemberID = id;
  }

  setIceServers(servers: string[]): void {
    this.iceServers = servers;
  }

  setStoredToken(token: string): void {
    this.storedToken = token;
    this.authenticated = true;
  }

  // --- Public methods for external orchestration ---

  getPeerConnection(): RTCPeerConnection | null {
    return this.pc;
  }

  getGatheredCandidateTypes(): string[] {
    return [...this.gatheredTypes];
  }

  isGatheringDone(): boolean {
    return this.gatheringDone;
  }

  handleRelayedMessage(payload: Record<string, unknown>): void {
    const type = payload.type as string;
    if (type === 'sdp_answer') {
      this.handleSdpAnswer(payload.sdp as string, payload.sdp_type as RTCSdpType);
    } else if (type === 'ice_candidate') {
      this.handleRemoteCandidate(payload.candidate as string, payload.mid as string);
    }
  }

  hasActivePeer(): boolean {
    return this.pc !== null && this.pc.connectionState !== 'closed';
  }

  restartOrRebuild(): void {
    if (this.hasActivePeer()) {
      console.log('[RTC] Active peer exists, attempting ICE restart instead of full rebuild');
      this.attemptIceRestart();
    } else {
      this.startWebRTC();
    }
  }

  warmup(): void {
    if (this.pc) return;
    console.log('[RTC] Warming up PeerConnection');
    this.pc = new RTCPeerConnection(this.buildPcConfig());
    this.gatheredTypes.clear();
    this.gatheringDone = false;
    this.pc.onicecandidate = (ev) => {
      if (ev.candidate) {
        const ct = ev.candidate.type;
        if (ct) this.gatheredTypes.add(ct);
      } else {
        this.gatheringDone = true;
      }
    };
  }

  startWebRTC(): void {
    this.stopPing();
    this.remoteDescriptionSet = false;
    this.pendingCandidates = [];

    const reuseWarmed = this.pc
      && this.pc.connectionState === 'new'
      && (this.iceServers.length === 0);

    if (!reuseWarmed) {
      this.dc?.close();
      this.pc?.close();
      this.pc = new RTCPeerConnection(this.buildPcConfig(this.iceServers));
      this.gatheredTypes.clear();
      this.gatheringDone = false;
    } else {
      console.log('[RTC] Reusing warmed PeerConnection');
    }

    this.dc = this.pc!.createDataChannel('kite', { ordered: true });

    this.dc.onopen = () => {
      console.log('[RTC] DataChannel open');
      this.startPing();
      this.notifyState('open');
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
        this.msgHandlers.forEach((h) => h(msg));
      } catch (e) {
        console.error('[RTC] DC message parse error:', e);
      }
    };

    this.dc.onclose = () => {
      console.log('[RTC] DataChannel closed');
      this.stopPing();
      this.notifyState('closed');
    };

    this.pc!.onicecandidate = (ev) => {
      if (ev.candidate) {
        // Track candidate type for UI display
        const ct = ev.candidate.type;
        if (ct) {
          this.gatheredTypes.add(ct);
          this.notifyState('connecting'); // trigger UI update with new candidate info
        }
        if (this.signal && this.daemonMemberID) {
          this.signal.relay(this.daemonMemberID, {
            type: 'ice_candidate',
            candidate: ev.candidate.candidate,
            mid: ev.candidate.sdpMid || '',
          });
        }
      } else {
        // null candidate = gathering complete
        this.gatheringDone = true;
        this.notifyState('connecting');
      }
    };

    this.pc.onconnectionstatechange = () => {
      const state = this.pc?.connectionState;
      console.log('[RTC] Connection state:', state);
      if (state === 'failed') {
        // ICE agent is terminal — full rebuild is the only option
        this.cancelRecovery();
        this.fullRebuild();
      } else if (state === 'disconnected') {
        // Immediately attempt ICE restart, with recovery timer as fallback
        if (this.signal?.isConnected() && this.daemonMemberID) {
          this.attemptIceRestart();
        }
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

  // --- Parallel Recovery ---

  startRecovery(): void {
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
    }, 5_000);
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

  attemptIceRestart(): void {
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
    this.notifyState('closed');
    this.appHandlers.forEach((h) => h({ type: 'disconnected' }));
  }

  // --- Visibility ---

  installVisibilityHandler(): void {
    this.removeVisibilityHandler();
    this.visibilityHandler = () => {
      if (document.visibilityState === 'visible') {
        // Always probe liveness
        if (this.dc?.readyState === 'open') {
          this.sendRaw({ type: 'ping' });
          this.sendRaw({ type: 'request_sync' });
        }
        // If PC exists but not connected, do parallel recovery
        const pcState = this.pc?.connectionState;
        if (pcState && pcState !== 'connected') {
          if (this.signal?.isConnected() && this.daemonMemberID) {
            this.attemptIceRestart();
          }
          this.startRecovery();
        }
        // If signal is down, force reconnect in parallel
        if (this.signal && !this.signal.isConnected()) {
          this.signal.forceReconnect();
        }
      }
    };
    document.addEventListener('visibilitychange', this.visibilityHandler);
  }

  removeVisibilityHandler(): void {
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler);
      this.visibilityHandler = null;
    }
  }

  // --- Private helpers ---

  private notifyState(state: TransportState): void {
    this.stateHandlers.forEach((h) => h(state));
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
    }, 5_000);
  }

  private stopPing(): void {
    if (this.pingInterval !== null) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }

  private sendRaw(msg: Record<string, unknown>): void {
    this.send(JSON.stringify(msg));
  }
}
