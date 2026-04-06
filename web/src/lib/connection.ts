import { TransportManager } from './transport';
import { WebRtcTransport } from './webrtc';
import { LanWebSocket } from './lan-ws';
import { SignalClient } from './signal';
import type { DaemonInfo, ServerMessage } from './types';

export const transport = new TransportManager();
const webrtcTransport = new WebRtcTransport();

let signalClient: SignalClient | null = null;
let lanWs: LanWebSocket | null = null;
let transportSetupDone = false;

type AppEventHandler = (msg: ServerMessage) => void;
const appEventHandlers: AppEventHandler[] = [];

export function onAppEvent(handler: AppEventHandler): () => void {
  appEventHandlers.push(handler);
  return () => {
    const idx = appEventHandlers.indexOf(handler);
    if (idx >= 0) appEventHandlers.splice(idx, 1);
  };
}

export async function connect(signalUrl: string, pairingCode: string): Promise<void> {
  signalClient = new SignalClient(signalUrl, pairingCode, 'browser');

  signalClient.onMessage((msg) => {
    switch (msg.type) {
      case 'joined': {
        let daemonInfo: DaemonInfo | null = null;
        if (msg.members) {
          const daemon = (msg.members as Array<{ id: string; role: string; lan_ip?: string; lan_port?: number; ice_servers?: string[] }>).find((m) => m.role === 'daemon');
          if (daemon) {
            daemonInfo = {
              member_id: daemon.id,
              lan_ip: daemon.lan_ip,
              lan_port: daemon.lan_port,
              ice_servers: daemon.ice_servers,
            };
          }
        }
        if (daemonInfo) {
          setupTransports(daemonInfo);
        }
        appEventHandlers.forEach((h) => h({ type: 'signal_connected' } as ServerMessage));
        break;
      }
      case 'member_joined': {
        if (msg.role === 'daemon' && msg.member_id) {
          const info: DaemonInfo = {
            member_id: msg.member_id,
            lan_ip: msg.lan_ip as string | undefined,
            lan_port: msg.lan_port as number | undefined,
            ice_servers: msg.ice_servers as string[] | undefined,
          };
          setupTransports(info);
        }
        break;
      }
      case 'member_left': {
        if (msg.member_id) {
          appEventHandlers.forEach((h) => h({ type: 'daemon_disconnected' } as ServerMessage));
        }
        break;
      }
      case 'relay': {
        if (msg.payload) {
          webrtcTransport.handleRelayedMessage(msg.payload as Record<string, unknown>);
        }
        break;
      }
    }
  });

  await signalClient.connect();
  webrtcTransport.installVisibilityHandler();
}

function setupTransports(daemon: DaemonInfo): void {
  // Setup WebRTC
  webrtcTransport.setSignal(signalClient!);
  webrtcTransport.setDaemonMemberID(daemon.member_id);
  if (daemon.ice_servers) {
    webrtcTransport.setIceServers(daemon.ice_servers);
  }

  if (!transportSetupDone) {
    transport.register(webrtcTransport);
    transportSetupDone = true;
  }

  webrtcTransport.startWebRTC();

  // Setup LAN WebSocket (if info available and not already created)
  if (daemon.lan_ip && daemon.lan_port && !lanWs) {
    lanWs = new LanWebSocket(daemon.lan_ip, daemon.lan_port);
    transport.register(lanWs);
    lanWs.connect().catch(() => {
      console.log('[Connection] LAN WS not available (not on same network)');
    });
  }
}

export function authenticate(token: string): void {
  transport.send({ type: 'auth', token });
  lanWs?.setToken(token);
  webrtcTransport.setStoredToken(token);
}

export function disconnect(): void {
  webrtcTransport.removeVisibilityHandler();
  transport.disconnect();
  signalClient?.disconnect();
  signalClient = null;
  lanWs = null;
  transportSetupDone = false;
}

export function isConnected(): boolean {
  return transport.isConnected();
}
