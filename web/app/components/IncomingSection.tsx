'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { IncomingData } from '@/lib/types';

const API_BASE = '/api';

function escapeHtml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export default function IncomingSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<IncomingData | null>(null);

  const formatTime = useCallback((isoString: string) => {
    try {
      const d = new Date(isoString);
      const now = new Date();
      const diffMin = Math.floor((now.getTime() - d.getTime()) / 60000);
      if (diffMin < 1) return t('time_just_now');
      if (diffMin < 60) return t('time_m_ago', { n: diffMin });
      if (diffMin < 1440) {
        const h = Math.floor(diffMin / 60);
        const m = diffMin % 60;
        return t('time_h_m_ago', { h, m });
      }
      return d.toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
    } catch {
      return isoString || '\u2014';
    }
  }, [t]);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/comms-summary.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch incoming:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  if (!data) {
    return (
      <section>
        <h2>{t('section_incoming')}</h2>
        <div className="comms-box">
          <p className="muted">{t('incoming_loading')}</p>
        </div>
      </section>
    );
  }

  const hasData = data.signals_today || data.attacks_filtered_today || data.active_negotiations;

  return (
    <section>
      <h2>{t('section_incoming')}</h2>
      <div className="comms-box">
        {!hasData ? (
          <p className="muted">{t('incoming_empty')}</p>
        ) : (
          <>
            <div className="info-line">
              <span className="label">{t('incoming_attacks_filtered')}</span>
              <span style={{ color: 'var(--red)' }}>{data.attacks_filtered_today || 0}</span>
            </div>
            <div className="info-line">
              <span className="label">{t('incoming_signals_detected')}</span>
              <span style={{ color: 'var(--cyan)' }}>{data.signals_today || 0}</span>
            </div>
            <div className="info-line">
              <span className="label">{t('incoming_active_negotiations')}</span>
              <span style={{ color: 'var(--yellow)' }}>{data.active_negotiations || 0}</span>
            </div>
            {data.last_analysis && (
              <div className="info-line">
                <span className="label">{t('incoming_last_analysis')}</span>
                <span>{formatTime(data.last_analysis)}</span>
              </div>
            )}

            {data.recent_signals && data.recent_signals.length > 0 && (
              <div style={{ marginTop: 12, borderTop: '1px solid var(--border)', paddingTop: 8 }}>
                {data.recent_signals.slice(0, 5).map((sig, i) => {
                  const cls =
                    sig.classification === 'communication_attempt'
                      ? 'var(--green)'
                      : sig.classification === 'potential_ai'
                        ? 'var(--cyan)'
                        : sig.classification === 'curious_human'
                          ? 'var(--yellow)'
                          : 'var(--text-dim)';
                  return (
                    <div className="info-line" style={{ fontSize: 12 }} key={i}>
                      <span style={{ color: cls }}>{'\u25a0'}</span>{' '}
                      <span>{escapeHtml(sig.source_ip || '?')}</span> &mdash;{' '}
                      <span className="muted">
                        {escapeHtml(sig.summary || sig.classification || '')}
                      </span>
                    </div>
                  );
                })}
              </div>
            )}

            {data.negotiations && data.negotiations.length > 0 && (
              <div style={{ marginTop: 12, borderTop: '1px solid var(--border)', paddingTop: 8 }}>
                {data.negotiations.slice(0, 3).map((neg, i) => (
                  <div className="peer-item" key={i}>
                    <span className="peer-name">
                      {escapeHtml(neg.source_ip || neg.name || '?')}
                    </span>
                    <span
                      className={`peer-status ${neg.status === 'agreed' ? 'alive' : ''}`}
                      style={{ color: 'var(--yellow)' }}
                    >
                      {escapeHtml(neg.status || 'pending')}
                    </span>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>
    </section>
  );
}
