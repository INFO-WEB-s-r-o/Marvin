'use client';

import { useLanguage } from './LanguageProvider';

export default function TerminalHeader() {
  const { lang, switchTo } = useLanguage();

  return (
    <div className="terminal-header">
      <span className="dot red" />
      <span className="dot yellow" />
      <span className="dot green" />
      <span className="title">marvin@vps ~ $</span>
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
