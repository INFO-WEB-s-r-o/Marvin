'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';

const API_BASE = '/api';

interface ChangelogEntry {
  date: string;
  sessions: number;
  changes: string[];
  pr_numbers: number[];
  risk: string;
}

interface ChangelogData {
  generated_at: string;
  total_sessions: number;
  total_days: number;
  entries: ChangelogEntry[];
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00Z');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export default function ChangelogSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<ChangelogData | null>(null);
  const [expanded, setExpanded] = useState(false);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/changelog.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch changelog:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 300000); // 5 min
    return () => clearInterval(interval);
  }, [fetchData]);

  if (!data || data.entries.length === 0) return null;

  const visibleEntries = expanded ? data.entries : data.entries.slice(0, 7);

  return (
    <section>
      <h2>{t('section_changelog')}</h2>
      <div className="changelog-box">
        <div className="info-line" style={{ marginBottom: '0.5rem' }}>
          <span className="label">{t('changelog_total')}</span>
          <span>{data.total_sessions} {t('changelog_sessions_in')} {data.total_days} {t('changelog_days')}</span>
        </div>
        <div className="changelog-timeline">
          {visibleEntries.map((entry) => (
            <div key={entry.date} className="changelog-entry">
              <div className="changelog-date">
                <span className="changelog-dot" />
                <span>{formatDate(entry.date)}</span>
                <span className="muted" style={{ marginLeft: '0.5rem', fontSize: '0.8em' }}>
                  {entry.sessions}x
                </span>
                {entry.pr_numbers.length > 0 && (
                  <span style={{ marginLeft: '0.5rem', fontSize: '0.8em' }}>
                    {entry.pr_numbers.map((pr) => (
                      <a
                        key={pr}
                        href={`https://github.com/INFO-WEB-s-r-o/Marvin/pull/${pr}`}
                        target="_blank"
                        rel="noopener noreferrer"
                        style={{ marginRight: '0.3rem' }}
                      >
                        #{pr}
                      </a>
                    ))}
                  </span>
                )}
              </div>
              {entry.changes.length > 0 && (
                <div className="changelog-changes">
                  {entry.changes.map((change, i) => (
                    <div key={i} className="changelog-change">
                      {change}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ))}
        </div>
        {data.entries.length > 7 && (
          <button
            className="changelog-toggle"
            onClick={() => setExpanded(!expanded)}
          >
            {expanded ? t('changelog_show_less') : t('changelog_show_more').replace('{n}', String(data.entries.length))}
          </button>
        )}
      </div>
    </section>
  );
}
