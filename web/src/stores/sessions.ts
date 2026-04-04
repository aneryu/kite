import { ws } from '../lib/ws';
import { fetchSessions } from '../lib/api';
import type { SessionInfo, ServerMessage } from '../lib/types';

type Listener = () => void;

class SessionStore {
  sessions: SessionInfo[] = [];
  private listeners: Listener[] = [];

  subscribe(fn: Listener) {
    this.listeners.push(fn);
    return () => { this.listeners = this.listeners.filter((l) => l !== fn); };
  }

  private notify() { this.listeners.forEach((fn) => fn()); }

  async load() {
    try {
      this.sessions = await fetchSessions();
      this.notify();
    } catch {}
  }

  getSession(id: number): SessionInfo | undefined {
    return this.sessions.find((s) => s.id === id);
  }

  handleMessage(msg: ServerMessage) {
    const sid = msg.session_id;
    if (!sid) return;

    switch (msg.type) {
      case 'session_state_change': {
        const s = this.getSession(sid);
        if (s && msg.state) { s.state = msg.state as SessionInfo['state']; this.notify(); }
        break;
      }
      case 'task_update': {
        const s = this.getSession(sid);
        if (!s || !msg.task_id) break;
        const existing = s.tasks.find((t) => t.id === msg.task_id);
        if (existing) { existing.completed = msg.completed ?? existing.completed; }
        else { s.tasks.push({ id: msg.task_id, subject: msg.subject ?? '', completed: msg.completed ?? false }); }
        this.notify();
        break;
      }
      case 'subagent_update': {
        const s = this.getSession(sid);
        if (!s || !msg.agent_id) break;
        const existing = s.subagents.find((a) => a.id === msg.agent_id);
        if (existing) { existing.completed = msg.completed ?? existing.completed; existing.elapsed_ms = msg.elapsed_ms ?? existing.elapsed_ms; }
        else { s.subagents.push({ id: msg.agent_id, type: msg.agent_type ?? '', completed: msg.completed ?? false, elapsed_ms: msg.elapsed_ms ?? 0 }); }
        this.notify();
        break;
      }
      case 'activity_update': {
        const s = this.getSession(sid);
        if (!s) break;
        s.activity = msg.tool_name ? { tool_name: msg.tool_name } : null;
        this.notify();
        break;
      }
      case 'prompt_request': {
        const s = this.getSession(sid);
        if (s) { s.state = 'waiting_input'; this.notify(); }
        break;
      }
    }
  }

  sorted(): SessionInfo[] {
    const priority: Record<string, number> = { waiting_input: 0, running: 1, starting: 2, stopped: 3 };
    return [...this.sessions].sort((a, b) => (priority[a.state] ?? 9) - (priority[b.state] ?? 9));
  }
}

export const sessionStore = new SessionStore();
ws.onMessage((msg) => sessionStore.handleMessage(msg));
