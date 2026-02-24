'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { StatusData } from '@/lib/types';

const API_BASE = '/api';
const SERVICES = ['nginx', 'fail2ban', 'cron', 'ssh'] as const;

export default function ServicesSection() {
  const { t } = useLanguage();
  const [checks, setChecks] = useState<Record<string, string>>({});

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

  return (
    <section>
      <h2>{t('section_services')}</h2>
      <div className="services-grid">
        {SERVICES.map((svc) => (
          <div
            key={svc}
            className={`service-item ${checks[svc] === 'active' ? 'active' : checks[svc] ? 'inactive' : ''}`}
          >
            <span className="svc-dot" /> {svc}
          </div>
        ))}
      </div>
    </section>
  );
}
