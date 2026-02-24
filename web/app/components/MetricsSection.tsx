'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { StatusData } from '@/lib/types';

const API_BASE = '/api';

function metricColor(percent: number): string {
  if (percent > 90) return 'var(--red)';
  if (percent > 75) return 'var(--yellow)';
  return 'var(--green)';
}

function barClass(percent: number): string {
  if (percent > 90) return 'metric-fill crit';
  if (percent > 75) return 'metric-fill warn';
  return 'metric-fill';
}

export default function MetricsSection() {
  const { t } = useLanguage();
  const [data, setData] = useState<StatusData | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/status.json?t=${Date.now()}`);
      if (resp.ok) setData(await resp.json());
    } catch (e) {
      console.warn('Failed to fetch metrics:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const m = data?.metrics;

  const cpuPercent = m?.cpu_percent ?? 0;
  const memPercent = m?.memory ? Math.round((m.memory.used / m.memory.total) * 100) : 0;
  const swapPercent = m?.swap && m.swap.total > 0 ? Math.round((m.swap.used / m.swap.total) * 100) : 0;
  const diskPercent = m?.disk ? parseInt(m.disk.percent) : 0;

  return (
    <section>
      <h2>{t('section_metrics')}</h2>
      <div className="metrics-grid">
        <MetricCard
          label={t('metric_cpu')}
          value={m ? `${m.cpu_percent}%` : '\u2014'}
          percent={cpuPercent}
        />
        <MetricCard
          label={t('metric_memory')}
          value={m?.memory ? `${m.memory.used}/${m.memory.total} MB` : '\u2014'}
          percent={memPercent}
        />
        <MetricCard
          label={t('metric_swap')}
          value={m?.swap && m.swap.total > 0 ? `${m.swap.used}/${m.swap.total} MB` : t('metric_swap_na')}
          percent={swapPercent}
        />
        <MetricCard
          label={t('metric_disk')}
          value={m?.disk ? m.disk.percent : '\u2014'}
          percent={diskPercent}
        />
      </div>
      <div className="metrics-extra">
        <div className="info-line">
          <span className="label">{t('label_load')}</span>
          <span>
            {m?.load_average
              ? `${m.load_average['1min']} / ${m.load_average['5min']} / ${m.load_average['15min']}`
              : '\u2014'}
          </span>
        </div>
        <div className="info-line">
          <span className="label">{t('label_processes')}</span>
          <span>{m?.process_count ?? '\u2014'}</span>
        </div>
        <div className="info-line">
          <span className="label">{t('label_banned')}</span>
          <span>{m?.fail2ban_banned ?? '0'}</span>
        </div>
      </div>
    </section>
  );
}

function MetricCard({ label, value, percent }: { label: string; value: string; percent: number }) {
  return (
    <div className="metric-card">
      <div className="metric-label">{label}</div>
      <div className="metric-value" style={{ color: metricColor(percent) }}>
        {value}
      </div>
      <div className="metric-bar">
        <div
          className={barClass(percent)}
          style={{ width: `${Math.min(percent, 100)}%` }}
        />
      </div>
    </div>
  );
}
