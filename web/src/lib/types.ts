export interface TaskInfo {
  id: string;
  subject: string;
  completed: boolean;
}

export interface SubagentInfo {
  id: string;
  type: string;
  completed: boolean;
  elapsed_ms: number;
}

export interface ActivityInfo {
  tool_name: string;
}

export interface SessionInfo {
  id: number;
  state: 'starting' | 'running' | 'idle' | 'waiting_input' | 'asking' | 'stopped';
  command: string;
  cwd: string;
  tasks: TaskInfo[];
  subagents: SubagentInfo[];
  activity: ActivityInfo | null;
}

export interface ServerMessage {
  type: string;
  session_id?: number;
  data?: string;
  state?: string;
  event?: string;
  tool?: string;
  tool_name?: string | null;
  task_id?: string;
  subject?: string;
  completed?: boolean;
  agent_id?: string;
  agent_type?: string;
  elapsed_ms?: number;
  summary?: string;
  options?: string[];
  question?: string;
  success?: boolean;
}
