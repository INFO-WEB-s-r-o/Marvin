import { TRANSLATIONS, type Lang } from './translations';

export type { Lang };

export function t(lang: Lang, key: string, params?: Record<string, string | number>): string {
  const str = TRANSLATIONS[lang]?.[key] || TRANSLATIONS.en[key] || key;
  if (!params) return str;
  return str.replace(/\{(\w+)\}/g, (match, name) =>
    params[name] !== undefined ? String(params[name]) : match
  );
}

export function detectLanguage(): Lang {
  if (typeof window === 'undefined') return 'en';
  const stored = localStorage.getItem('marvin-lang');
  if (stored && (stored === 'en' || stored === 'cs')) return stored;
  const browserLangs = navigator.languages || [navigator.language || 'en'];
  for (const lang of browserLangs) {
    const code = lang.toLowerCase().split('-')[0];
    if (code === 'cs' || code === 'en') return code as Lang;
  }
  return 'en';
}
