'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { ThoughtsData } from '@/lib/types';

const API_BASE = '/api';

function escapeHtml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

const CATEGORY_ICONS: Record<string, string> = {
  intention: '\u25b6',   // right triangle
  observation: '\u25c6', // diamond
  reflection: '\u25cb',  // circle
};

export default function ThoughtsSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<ThoughtsData | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/thoughts.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch thoughts:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 120000);
    return () => clearInterval(interval);
  }, [fetchData]);

  if (!data) {
    return (
      <section>
        <h2>{t('section_thoughts')}</h2>
        <div className="comms-box">
          <p className="muted">{t('thoughts_loading')}</p>
        </div>
      </section>
    );
  }

  if (!data.thoughts || data.thoughts.length === 0) {
    return (
      <section>
        <h2>{t('section_thoughts')}</h2>
        <div className="comms-box">
          <p className="muted">{t('thoughts_empty')}</p>
        </div>
      </section>
    );
  }

  return (
    <section>
      <h2>{t('section_thoughts')}</h2>
      <div className="comms-box">
        {data.thoughts.map((thought, i) => (
          <div key={i} style={{
            padding: '4px 0',
            borderBottom: i < data.thoughts.length - 1 ? '1px solid var(--border, #333)' : 'none',
          }}>
            <span style={{ marginRight: '6px', opacity: 0.6 }}>
              {CATEGORY_ICONS[thought.category] || '\u2022'}
            </span>
            <span className="muted" style={{ fontSize: '0.75em', marginRight: '8px' }}>
              {t(`thoughts_${thought.category}`)}
            </span>
            <span style={{ fontSize: '0.9em' }}>
              {escapeHtml(thought.text)}
            </span>
            <span className="muted" style={{ fontSize: '0.7em', marginLeft: '8px' }}>
              {escapeHtml(thought.date)}
            </span>
          </div>
        ))}
        <p className="muted" style={{ marginTop: '8px', fontSize: '0.8em' }}>
          {t('thoughts_from', { n: data.source_count })}
        </p>
      </div>
    </section>
  );
}
