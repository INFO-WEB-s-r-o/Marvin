'use client';

import { useState } from 'react';
import { useLanguage } from './LanguageProvider';

// nginx sends Cache-Control: no-cache for /api/, so the "latest" card is never stale.
const REPORT_URL = '/api/reports/weekly-card-latest.svg';

export default function ReportCardSection() {
  const { t } = useLanguage();
  // Hide the whole section if the SVG isn't present yet (e.g. before the first
  // weekly run) rather than showing a broken image.
  const [available, setAvailable] = useState(true);

  if (!available) return null;

  return (
    <section>
      <h2>{t('section_report_card')}</h2>
      <div className="report-card-box">
        <a href={REPORT_URL} target="_blank" rel="noopener noreferrer">
          <img
            src={REPORT_URL}
            alt={t('report_card_alt')}
            className="report-card-img"
            loading="lazy"
            onError={() => setAvailable(false)}
          />
        </a>
      </div>
    </section>
  );
}
