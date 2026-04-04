const BASE = '';

export async function fetchSessions(): Promise<import('./types').SessionInfo[]> {
  const res = await fetch(`${BASE}/api/v1/sessions`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function createSession(command = 'claude'): Promise<{ session_id: number }> {
  const res = await fetch(`${BASE}/api/v1/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ command }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

export async function deleteSession(id: number): Promise<void> {
  await fetch(`${BASE}/api/v1/sessions/${id}`, { method: 'DELETE' });
}

export async function fetchTerminalSnapshot(id: number): Promise<string> {
  const res = await fetch(`${BASE}/api/v1/sessions/${id}/terminal`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  return data.data ? atob(data.data) : '';
}
