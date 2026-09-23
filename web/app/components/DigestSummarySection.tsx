'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';

const API_BASE = '/api';

interface DigestSummary {
  date: string;
  generated_at: string;
  session_limit_throttles: number;
}

// Low-key visibility for Claude session-limit throttles (self-resolving,
// never paged as an alert — see fail_reason: "session_limit" in run_claude()).
// Reads the curated public subset at /api/digest-summary.json, not the
// internal data/logs/digest-latest.json (kept off the public surface by #861).
// Renders nothing on a clean day or if the fetch fails — this is an FYI
// footnote, not an alert, so a fetch hiccup should stay silent rather than
// show an error state for a non-critical metric.
export default function DigestSummarySection() {
  const { t } = useLanguage();
  const [summary, setSummary] = useState<DigestSummary | null>(null);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/digest-summary.json?t=${Date.now()}`);
      if (resp.ok) setSummary(await resp.json());
    } catch {
      // Silent — see comment above.
    }
  }, []);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 300000);
    return () => clearInterval(interval);
  }, [fetchData]);

  const throttles = summary?.session_limit_throttles ?? 0;
  if (throttles <= 0) return null;

  return (
    <p style={{ fontSize: '0.85em', opacity: 0.7, marginTop: '4px' }}>
      {t('digest_throttle_note', { n: throttles })}
    </p>
  );
}
