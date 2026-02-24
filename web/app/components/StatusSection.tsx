'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { StatusData, UptimeData } from '@/lib/types';

const API_BASE = '/api';

function escapeHtml(str: string): string {
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

export default function StatusSection() {
  const { t } = useLanguage();
  const [status, setStatus] = useState<StatusData | null>(null);
  const [uptime, setUptime] = useState<UptimeData | null>(null);

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
      const [statusResp, uptimeResp] = await Promise.all([
        fetch(`${API_BASE}/status.json?t=${Date.now()}`),
        fetch(`${API_BASE}/uptime.json?t=${Date.now()}`),
      ]);
      if (statusResp.ok) setStatus(await statusResp.json());
      if (uptimeResp.ok) setUptime(await uptimeResp.json());
    } catch (e) {
      console.warn('Failed to fetch status:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const statusText = status
    ? {
        healthy: t('status_healthy'),
        warning: t('status_warning', { n: status.issues_count }),
        critical: t('status_critical', { n: status.issues_count }),
        unknown: t('status_unknown'),
      }[status.status] || t('status_unknown')
    : t('status_loading');

  return (
    <section>
      <h2>{t('section_status')}</h2>
      <div className={`status-box ${status?.status || 'loading'}`}>
        <span className="status-dot" />
        <span>{statusText}</span>
      </div>
      <div className="info-line">
        <span className="label">{t('label_uptime')}</span>
        <span>
          {uptime
            ? t('uptime_format', { d: uptime.days, h: uptime.hours, s: uptime.seconds.toLocaleString() })
            : '\u2014'}
        </span>
      </div>
      <div className="info-line">
        <span className="label">{t('label_last_check')}</span>
        <span>{status ? formatTime(status.timestamp) : '\u2014'}</span>
      </div>

      {status?.issues && status.issues.length > 0 && (
        <section style={{ marginTop: '16px' }}>
          <h2>{t('section_issues')}</h2>
          <div className="issues-box">
            {status.issues.map((issue, i) => (
              <div
                key={i}
                className={`issue-item ${issue.startsWith('CRITICAL') ? 'critical' : 'warning'}`}
              >
                {escapeHtml(issue)}
              </div>
            ))}
          </div>
        </section>
      )}
    </section>
  );
}
