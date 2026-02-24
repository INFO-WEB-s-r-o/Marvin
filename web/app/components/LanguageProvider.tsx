'use client';

import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from 'react';
import { type Lang, detectLanguage, t as translate } from '@/lib/i18n';

interface LanguageContextType {
  lang: Lang;
  switchTo: (lang: Lang) => void;
  t: (key: string, params?: Record<string, string | number>) => string;
}

const LanguageContext = createContext<LanguageContextType>({
  lang: 'en',
  switchTo: () => {},
  t: (key) => key,
});

export function LanguageProvider({ children }: { children: ReactNode }) {
  const [lang, setLang] = useState<Lang>('en');

  useEffect(() => {
    setLang(detectLanguage());
  }, []);

  const switchTo = useCallback((newLang: Lang) => {
    setLang(newLang);
    localStorage.setItem('marvin-lang', newLang);
    document.documentElement.lang = newLang;
  }, []);

  const t = useCallback(
    (key: string, params?: Record<string, string | number>) => translate(lang, key, params),
    [lang]
  );

  return (
    <LanguageContext.Provider value={{ lang, switchTo, t }}>
      {children}
    </LanguageContext.Provider>
  );
}

export function useLanguage() {
  return useContext(LanguageContext);
}
