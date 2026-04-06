export type ThemeId = 'cyber-dark' | 'cyber-light' | 'monokai' | 'nord' | 'auto';

export const THEME_LABELS: Record<ThemeId, string> = {
  'auto': 'Auto',
  'cyber-dark': 'Cyber Dark',
  'cyber-light': 'Cyber Light',
  'monokai': 'Monokai',
  'nord': 'Nord',
};

export const THEME_IDS: ThemeId[] = ['auto', 'cyber-dark', 'cyber-light', 'monokai', 'nord'];

const STORAGE_KEY = 'kite-theme';

export function getStoredTheme(): ThemeId {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored && stored in THEME_LABELS) return stored as ThemeId;
  return 'cyber-dark';
}

export function setStoredTheme(id: ThemeId): void {
  localStorage.setItem(STORAGE_KEY, id);
}

function resolveTheme(id: ThemeId): string {
  if (id !== 'auto') return id;
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'cyber-light' : 'cyber-dark';
}

export function applyTheme(id: ThemeId): void {
  const resolved = resolveTheme(id);
  document.documentElement.setAttribute('data-theme', resolved);
  setStoredTheme(id);
}

export function initTheme(): () => void {
  const stored = getStoredTheme();
  applyTheme(stored);

  const mql = window.matchMedia('(prefers-color-scheme: light)');
  const handler = () => {
    if (getStoredTheme() === 'auto') {
      applyTheme('auto');
    }
  };
  mql.addEventListener('change', handler);
  return () => mql.removeEventListener('change', handler);
}
