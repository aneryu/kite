export interface TaskInfo {
  id: string;
  subject: string;
  completed: boolean;
}

export interface SubagentInfo {
  id: string;
  type: string;
  description: string;
  completed: boolean;
  elapsed_ms: number;
}

export interface ActivityInfo {
  tool_name: string;
}

export interface QuestionInfo {
  question: string;
  options: string[];
}

export interface PromptInfo {
  summary: string;
  options: string[];
  questions?: QuestionInfo[];
}

export interface SessionInfo {
  id: number;
  state: 'running' | 'asking' | 'waiting_permission' | 'waiting' | 'stopped';
  command: string;
  cwd: string;
  tasks: TaskInfo[];
  subagents: SubagentInfo[];
  activity: ActivityInfo | null;
  prompt: PromptInfo | null;
  last_message: string | null;
}

export interface DaemonInfo {
  member_id: string;
  lan_ip?: string;
  lan_port?: number;
  ice_servers?: string[];
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
  description?: string;
  elapsed_ms?: number;
  summary?: string;
  options?: string[];
  questions?: QuestionInfo[];
  question?: string;
  success?: boolean;
  token?: string;
  last_message?: string | null;
  member_id?: string;
  role?: string;
  members?: Array<{ id: string; role: string; lan_ip?: string; lan_port?: number; ice_servers?: string[] }>;
  lan_ip?: string;
  lan_port?: number;
  ice_servers?: string[];
  error?: string;
  payload?: Record<string, unknown>;
}
