'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';

const API_BASE = '/api';

interface Incident {
  id: string;
  type: string;
  severity: string;
  title: string;
  detail: string;
  opened_at?: string;
  detected_at?: string;
  status?: string;
}

interface SummaryData {
  timestamp: string;
  active_incidents?: number;
  total?: number;
  critical_incidents?: number;
  critical?: number;
  incidents?: Incident[];
}

interface AlertData {
  timestamp: string;
  active_alerts: number;
  critical_alerts: number;
  alerts: Array<{
    id: string;
    severity: string;
    title: string;
    detail: string;
    count: number;
    first_seen: string;
    last_seen: string;
  }>;
}

function timeAgo(isoString: string | undefined, t: (key: string, params?: Record<string, string | number>) => string): string {
  if (!isoString) return '\u2014';
  try {
    const d = new Date(isoString);
    if (isNaN(d.getTime())) return isoString;
    const now = new Date();
    const diffMin = Math.floor((now.getTime() - d.getTime()) / 60000);
    if (diffMin < 1) return t('time_just_now');
    if (diffMin < 60) return t('time_m_ago', { n: diffMin });
    const h = Math.floor(diffMin / 60);
    if (h < 24) return t('time_h_ago', { n: h });
    const days = Math.floor(h / 24);
    return t('time_d_ago', { n: days });
  } catch {
    return isoString || '\u2014';
  }
}

export default function AlertsSection() {
  const { t } = useLanguage();
  const [summary, setSummary] = useState<SummaryData | null>(null);
  const [alerts, setAlerts] = useState<AlertData | null>(null);
  const [fetchError, setFetchError] = useState(false);

  const fetchData = useCallback(async () => {
    try {
      const [sumResp, alertResp] = await Promise.all([
        fetch(`${API_BASE}/incidents/summary.json?t=${Date.now()}`),
        fetch(`${API_BASE}/alerts/active-alerts.json?t=${Date.now()}`),
      ]);
      if (sumResp.ok) setSummary(await sumResp.json());
      if (alertResp.ok) setAlerts(await alertResp.json());
      setFetchError(!sumResp.ok && !alertResp.ok);
    } catch (e) {
      console.warn('Failed to fetch alerts:', e);
      setFetchError(true);
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  // Handle both data formats (active_incidents or total)
  const incidentCount = summary?.active_incidents ?? summary?.total ?? 0;
  const alertCount = alerts?.active_alerts ?? 0;
  const activeCount = incidentCount + alertCount;
  const hasCritical = (summary?.critical_incidents ?? summary?.critical ?? 0) > 0
    || (alerts?.critical_alerts ?? 0) > 0;

  // Only render when there are active alerts/incidents (or fetch error)
  if (activeCount === 0 && !fetchError) return null;

  const activeIncidents = (summary?.incidents ?? []).filter(
    (inc) => inc.status === 'active' || inc.status === undefined
  );

  return (
    <section>
      <h2>{t('section_alerts')}</h2>
      <div className={`status-box ${hasCritical ? 'critical' : 'warning'}`}>
        <span className="status-dot" />
        <span>
          {hasCritical
            ? t('alerts_critical', { n: activeCount })
            : t('alerts_warning', { n: activeCount })}
        </span>
      </div>

      {activeIncidents.length > 0 && (
        <div className="issues-box" style={{ marginTop: '8px' }}>
          {activeIncidents.map((inc) => (
            <div
              key={inc.id}
              className={`issue-item ${inc.severity === 'critical' ? 'critical' : 'warning'}`}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span>{inc.title}</span>
                <span style={{ fontSize: '0.8em', opacity: 0.7 }}>
                  {timeAgo(inc.opened_at || inc.detected_at, t)}
                </span>
              </div>
              {inc.detail && (
                <div style={{ fontSize: '0.85em', opacity: 0.8, marginTop: '2px' }}>
                  {inc.detail}
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {alerts?.alerts && alerts.alerts.length > 0 && (
        <div className="issues-box" style={{ marginTop: '8px' }}>
          {alerts.alerts.map((alert, i) => (
            <div
              key={alert.id || i}
              className={`issue-item ${alert.severity === 'critical' ? 'critical' : 'warning'}`}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span>{alert.title}</span>
                <span style={{ fontSize: '0.8em', opacity: 0.7 }}>
                  {alert.count > 1 ? `${alert.count}x ` : ''}{timeAgo(alert.last_seen, t)}
                </span>
              </div>
              {alert.detail && (
                <div style={{ fontSize: '0.85em', opacity: 0.8, marginTop: '2px' }}>
                  {alert.detail}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
      {fetchError && activeCount === 0 && (
        <div className="status-box warning" style={{ marginTop: '8px' }}>
          <span className="status-dot" />
          <span>{t('alerts_fetch_error')}</span>
        </div>
      )}
    </section>
  );
}
