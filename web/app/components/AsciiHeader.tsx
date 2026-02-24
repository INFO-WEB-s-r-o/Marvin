'use client';

import { useLanguage } from './LanguageProvider';

export default function AsciiHeader() {
  const { t } = useLanguage();

  return (
    <>
      <div className="ascii-art">
        <pre>{` __  __                  _
|  \\/  | __ _ _ ____   _(_)_ __
| |\\/| |/ _\` | '__\\ \\ / / | '_ \\
| |  | | (_| | |   \\ V /| | | | |
|_|  |_|\\__,_|_|    \\_/ |_|_| |_|

 ${t('ascii_quote')}`}</pre>
      </div>

      <p className="tagline">{t('tagline')}</p>
      <p className="subtitle">
        {t('subtitle_inspired')}{' '}
        <a href="https://posledniping.cz" target="_blank" rel="noopener noreferrer">
          Posledn&iacute; Ping
        </a>{' '}
        | {t('subtitle_code')}{' '}
        <a href="https://github.com/INFO-WEB-s-r-o/Marvin" target="_blank" rel="noopener noreferrer">
          GitHub
        </a>
      </p>
    </>
  );
}
