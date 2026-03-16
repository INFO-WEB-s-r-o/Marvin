'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { StatusData } from '@/lib/types';

const API_BASE = '/api';
const SERVICES = ['nginx', 'fail2ban', 'cron', 'ssh', 'marvin_web'] as const;
const SERVICE_LABELS: Record<string, string> = {
  nginx: 'nginx',
  fail2ban: 'fail2ban',
  cron: 'cron',
  ssh: 'ssh',
  marvin_web: 'dashboard',
};

export default function ServicesSection() {
  const { t } = useLanguage();
  const [checks, setChecks] = useState<Record<string, string | number | null>>({});

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/status.json?t=${Date.now()}`);
      if (resp.ok) {
        const data: StatusData = await resp.json();
        if (data.checks) setChecks(data.checks);
      }
    } catch (e) {
      console.warn('Failed to fetch services:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const sslDays = typeof checks.ssl_min_days === 'number' ? checks.ssl_min_days : null;
  const dnsStatus = checks.dns as string | undefined;
  const pingMs = checks.ping_ms as number | null;
  const httpsMs = checks.https_ms as number | null;

  return (
    <section>
      <h2>{t('section_services')}</h2>
      <div className="services-grid">
        {SERVICES.map((svc) => (
          <div
            key={svc}
            className={`service-item ${checks[svc] === 'active' ? 'active' : checks[svc] ? 'inactive' : ''}`}
          >
            <span className="svc-dot" /> {SERVICE_LABELS[svc] || svc}
          </div>
        ))}
      </div>
      <div className="metrics-extra" style={{ marginTop: '8px' }}>
        <div className="info-line">
          <span className="label">{t('label_ssl_days')}</span>
          <span style={{ color: sslDays !== null ? (sslDays < 14 ? 'var(--red)' : sslDays < 30 ? 'var(--yellow)' : 'var(--green)') : undefined }}>
            {sslDays !== null ? t('ssl_days_value', { n: sslDays }) : '\u2014'}
          </span>
        </div>
        <div className="info-line">
          <span className="label">{t('label_dns')}</span>
          <span style={{ color: dnsStatus === 'ok' ? 'var(--green)' : dnsStatus === 'failing' ? 'var(--red)' : undefined }}>
            {dnsStatus === 'ok' ? 'OK' : dnsStatus === 'failing' ? 'FAILING' : dnsStatus || '\u2014'}
          </span>
        </div>
        <div className="info-line">
          <span className="label">{t('label_ping')}</span>
          <span style={{ color: pingMs !== null ? (pingMs > 100 ? 'var(--red)' : pingMs > 50 ? 'var(--yellow)' : 'var(--green)') : undefined }}>
            {pingMs !== null ? `${pingMs} ms` : '\u2014'}
          </span>
        </div>
        <div className="info-line">
          <span className="label">{t('label_https_rt')}</span>
          <span style={{ color: httpsMs !== null ? (httpsMs > 5000 ? 'var(--red)' : httpsMs > 2000 ? 'var(--yellow)' : 'var(--green)') : undefined }}>
            {httpsMs !== null ? `${httpsMs} ms` : '\u2014'}
          </span>
        </div>
      </div>
    </section>
  );
}
