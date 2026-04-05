const TOKEN_KEY = 'kite_session_token';
const PAIRING_KEY = 'kite_pairing_code';
const SECRET_KEY = 'kite_setup_secret';

export function getStoredToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setStoredToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
}

export function clearStoredToken(): void {
  localStorage.removeItem(TOKEN_KEY);
}

export function getStoredPairingCode(): string | null {
  return localStorage.getItem(PAIRING_KEY);
}

export function setStoredPairingCode(code: string): void {
  localStorage.setItem(PAIRING_KEY, code);
}

export function clearStoredPairingCode(): void {
  localStorage.removeItem(PAIRING_KEY);
}

/** Parse pairing_code and setup_secret from URL hash: #/pair/{code}:{secret} */
export function parsePairingFromHash(): { pairingCode: string; setupSecret: string } | null {
  const hash = window.location.hash;
  const match = hash.match(/^#\/pair\/([a-z0-9]{6}):([a-f0-9]{64})$/);
  if (!match) return null;
  return { pairingCode: match[1], setupSecret: match[2] };
}

export function getStoredSecret(): string | null {
  return localStorage.getItem(SECRET_KEY);
}

export function setStoredSecret(secret: string): void {
  localStorage.setItem(SECRET_KEY, secret);
}

export function clearStoredSecret(): void {
  localStorage.removeItem(SECRET_KEY);
}

export function clearPairingFromHash(): void {
  history.replaceState({}, '', window.location.pathname);
}
