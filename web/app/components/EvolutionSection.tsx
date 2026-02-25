'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { EnhancementsData } from '@/lib/types';

const API_BASE = '/api';

function escapeHtml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export default function EvolutionSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<EnhancementsData | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/enhancements.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch enhancements:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  return (
    <section>
      <h2>{t('section_evolution')}</h2>
      <div className="evolution-box">
        <div className="info-line">
          <span className="label">{t('label_enhancements')}</span>
          <span>{data?.completed ?? '\u2014'} / {data?.total ?? '\u2014'}</span>
        </div>
        <div className="metric-bar" style={{ margin: '0.5rem 0' }}>
          <div
            className="metric-fill"
            style={{ width: `${data?.progress_pct ?? 0}%` }}
          />
        </div>
        <div className="info-line">
          <span className="label">{t('label_progress')}</span>
          <span>{data?.progress_pct ?? '\u2014'}%</span>
        </div>
        {data?.recent_completed && data.recent_completed.length > 0 && (
          <div className="muted" style={{ marginTop: '0.5rem', fontSize: '0.85em' }}>
            {t('label_recently')}
            <br />
            {data.recent_completed.map((item, i) => (
              <span key={i}>
                &nbsp;&nbsp;✓ {escapeHtml(item)}
                <br />
              </span>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
