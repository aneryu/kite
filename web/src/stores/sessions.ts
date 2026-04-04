import { ws } from '../lib/ws';
import { fetchSessions } from '../lib/api';
import type { SessionInfo, ServerMessage, QuestionInfo } from '../lib/types';

type Listener = () => void;

class SessionStore {
  sessions: SessionInfo[] = [];
  prompts: Map<number, { summary: string; options: string[]; questions?: QuestionInfo[] }> = new Map();
  private listeners: Listener[] = [];

  subscribe(fn: Listener) {
    this.listeners.push(fn);
    return () => { this.listeners = this.listeners.filter((l) => l !== fn); };
  }

  private notify() { this.listeners.forEach((fn) => fn()); }

  async load() {
    try {
      const newSessions = await fetchSessions();
      this.sessions = newSessions;
      // Clean up prompts for sessions that no longer exist
      const ids = new Set(newSessions.map((s) => s.id));
      for (const [id] of this.prompts) {
        if (!ids.has(id)) this.prompts.delete(id);
      }
      // Update prompts from server data (don't clear existing valid ones)
      for (const s of this.sessions) {
        if (s.prompt && (s.state === 'asking' || s.state === 'waiting_input')) {
          this.prompts.set(s.id, { summary: s.prompt.summary, options: s.prompt.options, questions: s.prompt.questions });
        } else if (s.state !== 'asking' && s.state !== 'waiting_input') {
          this.prompts.delete(s.id);
        }
      }
      this.notify();
    } catch {}
  }

  getSession(id: number): SessionInfo | undefined {
    return this.sessions.find((s) => s.id === id);
  }

  handleMessage(msg: ServerMessage & { sessions?: SessionInfo[]; last_message?: string | null }) {
    // Full state sync from WebSocket connect
    if (msg.type === 'sessions_sync' && msg.sessions) {
      this.sessions = msg.sessions;
      // Rebuild prompts from server data; clean up stale ones
      const newPrompts = new Map<number, { summary: string; options: string[]; questions?: QuestionInfo[] }>();
      for (const s of this.sessions) {
        if (s.prompt && (s.state === 'asking' || s.state === 'waiting_input')) {
          newPrompts.set(s.id, { summary: s.prompt.summary, options: s.prompt.options, questions: s.prompt.questions });
        } else if (this.prompts.has(s.id) && (s.state === 'asking' || s.state === 'waiting_input')) {
          newPrompts.set(s.id, this.prompts.get(s.id)!);
        }
      }
      this.prompts = newPrompts;
      this.notify();
      return;
    }

    const sid = msg.session_id;
    if (!sid) return;

    switch (msg.type) {
      case 'session_state_change': {
        const s = this.getSession(sid);
        if (!s) {
          // Unknown session — reload from server
          this.load();
          break;
        }
        if (msg.state) {
          s.state = msg.state as SessionInfo['state'];
          if (msg.state !== 'waiting_input' && msg.state !== 'asking') {
            this.prompts.delete(sid);
          }
          this.notify();
        }
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
        let s = this.getSession(sid);
        if (!s) {
          this.load();
          break;
        }
        s.state = (msg.state as SessionInfo['state']) ?? 'waiting_input';
        // Store questions as-is; summary/options only used for non-question prompts (Stop event)
        this.prompts.set(sid, {
          summary: msg.summary ?? '',
          options: msg.options ?? [],
          questions: msg.questions,
        });
        this.notify();
        break;
      }
      case 'last_message_update': {
        const s = this.getSession(sid);
        if (!s) break;
        s.last_message = msg.last_message ?? null;
        this.notify();
        break;
      }
    }
  }

  sorted(): SessionInfo[] {
    const priority: Record<string, number> = { asking: 0, waiting_input: 0, running: 1, idle: 2, starting: 3 };
    return [...this.sessions]
      .filter((s) => s.state !== 'stopped')
      .sort((a, b) => (priority[a.state] ?? 9) - (priority[b.state] ?? 9));
  }
}

export const sessionStore = new SessionStore();
ws.onMessage((msg) => sessionStore.handleMessage(msg));
