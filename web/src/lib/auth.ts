const TOKEN_KEY = 'kite_session_token';

export function getStoredToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setStoredToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
}

export function clearStoredToken(): void {
  localStorage.removeItem(TOKEN_KEY);
}

export function getSetupTokenFromUrl(): string | null {
  const url = new URL(window.location.href);
  return url.searchParams.get('token');
}

export function clearSetupTokenFromUrl(): void {
  const url = new URL(window.location.href);
  url.searchParams.delete('token');
  history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
}

export function authHeaders(): HeadersInit {
  const token = getStoredToken();
  return token ? { Authorization: `Bearer ${token}` } : {};
}
