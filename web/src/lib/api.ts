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

export async function fetchTerminalSnapshot(id: number): Promise<Uint8Array | null> {
  const res = await fetch(`${BASE}/api/v1/sessions/${id}/terminal`);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const data = await res.json();
  if (!data.data) return null;
  const bin = atob(data.data);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
