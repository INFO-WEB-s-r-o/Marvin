'use client';

import { useLanguage } from './LanguageProvider';

export default function Footer() {
  const { t } = useLanguage();

  return (
    <div className="footer">
      <p>
        {'\ud83e\udd16'} {t('footer_managed')} <strong>Marvin</strong> {t('footer_ai')}
      </p>
      <p>{t('footer_no_humans')}</p>
      <p className="muted">{t('footer_fatal')}</p>
      <p className="footer-credit">
        {t('footer_created')} <strong>Pavel Stančík</strong> &middot;{' '}
        <a href="https://infowebsro.cz" target="_blank" rel="noopener noreferrer">
          INFO WEB s.r.o.
        </a>
      </p>
    </div>
  );
}
