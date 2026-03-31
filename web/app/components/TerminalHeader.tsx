'use client';

import { useLanguage } from './LanguageProvider';
import { useTheme } from './ThemeProvider';

export default function TerminalHeader() {
  const { lang, switchTo } = useLanguage();
  const { theme, toggleTheme } = useTheme();

  return (
    <div className="terminal-header">
      <span className="dot red" />
      <span className="dot yellow" />
      <span className="dot green" />
      <span className="title">marvin@vps ~ $</span>
      <button
        className="theme-toggle"
        onClick={toggleTheme}
        title={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
      >
        {theme === 'dark' ? '\u2600' : '\u263E'}
      </button>
      <div className="lang-switcher">
        <button
          className={`lang-btn ${lang === 'en' ? 'active' : ''}`}
          onClick={() => switchTo('en')}
        >
          EN
        </button>
        <span className="lang-sep">|</span>
        <button
          className={`lang-btn ${lang === 'cs' ? 'active' : ''}`}
          onClick={() => switchTo('cs')}
        >
          CZ
        </button>
      </div>
    </div>
  );
}
