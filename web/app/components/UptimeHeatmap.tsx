'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { SlaData } from '@/lib/types';

const API_BASE = '/api';

function uptimeColor(pct: number): string {
  if (pct >= 100) return 'var(--green-bright)';
  if (pct >= 99.5) return 'var(--green)';
  if (pct >= 99) return 'var(--yellow)';
  if (pct >= 95) return 'var(--orange)';
  return 'var(--red)';
}

function uptimeClass(pct: number): string {
  if (pct >= 100) return 'perfect';
  if (pct >= 99.5) return 'good';
  if (pct >= 99) return 'degraded';
  return 'poor';
}

export default function UptimeHeatmap() {
  const { t } = useLanguage();
  const [sla, setSla] = useState<SlaData | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/metrics/sla.json?t=${Date.now()}`);
      if (resp.ok) {
        const data: SlaData = await resp.json();
        setSla(data);
      }
    } catch (e) {
      console.warn('Failed to fetch SLA data:', e);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 300000); // refresh every 5 min
    return () => clearInterval(interval);
  }, [fetchData]);

  if (!sla || !sla.days || sla.days.length === 0) return null;

  // Build a map of date -> uptime for quick lookup
  const uptimeMap = new Map<string, number>();
  for (const day of sla.days) {
    uptimeMap.set(day.date, day.uptime_pct);
  }

  // Generate last 30 days
  const today = new Date();
  const cells: Array<{ date: string; pct: number | null; label: string }> = [];
  for (let i = 29; i >= 0; i--) {
    const d = new Date(today);
    d.setDate(d.getDate() - i);
    const dateStr = d.toISOString().slice(0, 10);
    const pct = uptimeMap.get(dateStr) ?? null;
    const dayLabel = `${d.getDate()}/${d.getMonth() + 1}`;
    cells.push({ date: dateStr, pct, label: dayLabel });
  }

  const overall = Math.min(sla.summary.overall_uptime_pct, 100).toFixed(2);
  const daysAt100 = sla.summary.days_at_100pct;
  const tracked = sla.summary.days_tracked;

  return (
    <section>
      <h2>{t('section_uptime')}</h2>
      <div className="uptime-heatmap">
        <div className="uptime-summary">
          <span className="uptime-overall" style={{ color: uptimeColor(parseFloat(overall)) }}>
            {overall}%
          </span>
          <span className="uptime-detail">
            {t('uptime_days_perfect', { n: daysAt100 })} / {t('uptime_days_tracked', { n: tracked })}
          </span>
        </div>
        <div className="heatmap-grid">
          {cells.map((cell) => (
            <div
              key={cell.date}
              className={`heatmap-cell ${cell.pct !== null ? uptimeClass(cell.pct) : 'no-data'}`}
              title={
                cell.pct !== null
                  ? `${cell.date}: ${cell.pct.toFixed(2)}%`
                  : `${cell.date}: ${t('uptime_no_data')}`
              }
              style={cell.pct !== null ? { backgroundColor: uptimeColor(cell.pct) } : undefined}
            />
          ))}
        </div>
        <div className="heatmap-labels">
          <span className="muted">{cells[0]?.label}</span>
          <span className="muted">{t('uptime_legend')}</span>
          <span className="muted">{cells[cells.length - 1]?.label}</span>
        </div>
        <div className="heatmap-legend">
          <span className="muted">{t('uptime_less')}</span>
          <div className="heatmap-cell no-data" />
          <div className="heatmap-cell poor" style={{ backgroundColor: 'var(--red)' }} />
          <div className="heatmap-cell degraded" style={{ backgroundColor: 'var(--yellow)' }} />
          <div className="heatmap-cell good" style={{ backgroundColor: 'var(--green)' }} />
          <div className="heatmap-cell perfect" style={{ backgroundColor: 'var(--green-bright)' }} />
          <span className="muted">{t('uptime_more')}</span>
        </div>
      </div>
    </section>
  );
}
