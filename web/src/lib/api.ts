import { authHeaders } from './auth';

const BASE = '';

export async function fetchSessions(): Promise<import('./types').SessionInfo[]> {
  const res = await fetch(`${BASE}/api/v1/sessions`, { headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function createSession(command = 'claude'): Promise<{ session_id: number }> {
  const res = await fetch(`${BASE}/api/v1/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ command }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function deleteSession(id: number): Promise<void> {
  const res = await fetch(`${BASE}/api/v1/sessions/${id}`, { method: 'DELETE', headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
}

export async function fetchTerminalSnapshot(id: number): Promise<Uint8Array | null> {
  const res = await fetch(`${BASE}/api/v1/sessions/${id}/terminal`, { headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  if (!data.data) return null;
  const bin = atob(data.data);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

export async function exchangeSetupToken(setupToken: string): Promise<string> {
  const res = await fetch(`${BASE}/api/v1/auth`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ setup_token: setupToken }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  if (!data.token) throw new Error('missing token');
  return data.token as string;
}
