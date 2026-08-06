'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { ExternalDomainsData, ExternalDomainData } from '@/lib/types';

const API_BASE = '/api';

const STATUS_COLOR: Record<ExternalDomainData['status'], string> = {
  healthy: 'var(--green)',
  warning: 'var(--yellow)',
  critical: 'var(--red)',
  failing: 'var(--red)',
};

function statusLabel(t: (k: string) => string, s: ExternalDomainData['status']): string {
  switch (s) {
    case 'healthy': return t('external_status_healthy');
    case 'warning': return t('external_status_warning');
    case 'critical': return t('external_status_critical');
    case 'failing': return t('external_status_failing');
  }
}

function sslColor(days: number | null): string | undefined {
  if (days === null) return undefined;
  if (days < 14) return 'var(--red)';
  if (days < 30) return 'var(--yellow)';
  return 'var(--green)';
}

export default function ExternalDomainsSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<ExternalDomainsData | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/external-domains.json?t=${Date.now()}`);
      if (resp.ok) {
        setData(await resp.json());
      }
    } catch (e) {
      console.warn('Failed to fetch external domains:', e);
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
        <h2>{t('section_external')}</h2>
        <div className="info-line">
          <span style={{ opacity: 0.6 }}>{t('external_loading')}</span>
        </div>
      </section>
    );
  }

  if (data.count === 0) {
    return (
      <section>
        <h2>{t('section_external')}</h2>
        <div className="info-line">
          <span style={{ opacity: 0.6 }}>{t('external_no_domains')}</span>
        </div>
      </section>
    );
  }

  return (
    <section>
      <h2>{t('section_external')}</h2>
      <div className="metrics-extra" style={{ marginTop: '8px' }}>
        {data.domains.map((d) => (
          <div key={d.id} className="info-line" style={{ display: 'flex', flexWrap: 'wrap', gap: '12px' }}>
            <span style={{ minWidth: '160px' }}>
              <a href={d.url} target="_blank" rel="noopener noreferrer" style={{ color: 'inherit' }}>
                {d.name}
              </a>
            </span>
            <span style={{ color: STATUS_COLOR[d.status], fontWeight: 'bold', minWidth: '60px' }}>
              [{statusLabel(t, d.status)}]
            </span>
            <span style={{ minWidth: '90px' }}>
              HTTP {d.http_code ?? '\u2014'}
            </span>
            <span style={{ minWidth: '90px' }}>
              {d.response_ms !== null ? `${d.response_ms} ms` : '\u2014'}
            </span>
            <span style={{ minWidth: '110px', color: sslColor(d.ssl_days) }}>
              SSL {d.ssl_days !== null ? `${d.ssl_days}d` : '\u2014'}
            </span>
            <span style={{ color: d.dns === 'ok' ? 'var(--green)' : d.dns === 'failing' ? 'var(--red)' : undefined }}>
              DNS {d.dns}
            </span>
            {/* The address the probe actually connected to. Present only for
                domains pinned to public DNS (#964): for those, "reachable" is a
                claim about the internet, and this is the evidence for it. Absent
                means the probe used the normal resolver — which, for a domain
                this host serves, means it never left the machine. */}
            {d.probed_ip ? (
              <span style={{ color: 'var(--green)' }} title={`Probed from outside via public DNS at ${d.probed_ip}`}>
                EXT {d.probed_ip}
              </span>
            ) : null}
          </div>
        ))}
      </div>
    </section>
  );
}
