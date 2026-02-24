'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { PeersData } from '@/lib/types';

const API_BASE = '/api';

function escapeHtml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export default function PeersSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<PeersData | null>(null);

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
      const resp = await fetch(`${API_BASE}/comms/peers.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch peers:', e);
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
        <h2>{t('section_peers')}</h2>
        <div className="comms-box">
          <p className="muted">{t('peers_scanning')}</p>
        </div>
      </section>
    );
  }

  return (
    <section>
      <h2>{t('section_peers')}</h2>
      <div className="comms-box">
        {!data.peers || data.peers.length === 0 ? (
          <>
            <p className="muted">{t('peers_empty')}</p>
            <p className="muted" style={{ marginTop: 8 }}>
              {t('peers_messages_sent')} {data.messages_sent || 0} |{' '}
              {t('peers_messages_received')} {data.messages_received || 0}
            </p>
            <p className="muted" style={{ marginTop: 4 }}>
              {t('peers_last_scan')}{' '}
              {data.last_scan ? formatTime(data.last_scan) : t('peers_never')}
            </p>
            <p style={{ marginTop: 12, color: 'var(--yellow)' }}>{t('peers_quote')}</p>
          </>
        ) : (
          <>
            {data.peers.map((peer, i) => (
              <div className="peer-item" key={i}>
                <span className="peer-name">{escapeHtml(peer.name || 'Unknown')}</span>
                <span className={`peer-status ${peer.alive ? 'alive' : 'dead'}`}>
                  {peer.alive ? t('peer_alive') : t('peer_unreachable')}
                </span>
              </div>
            ))}
            <p className="muted" style={{ marginTop: 12 }}>
              {t('peers_total')} {data.peers.length} | {t('peers_sent')}{' '}
              {data.messages_sent || 0} | {t('peers_received')}{' '}
              {data.messages_received || 0}
            </p>
          </>
        )}
      </div>
    </section>
  );
}
