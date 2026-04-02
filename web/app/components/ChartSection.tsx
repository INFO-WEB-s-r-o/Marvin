'use client';

import { useRef, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import type { MetricsHistory } from '@/lib/types';

const API_BASE = '/api';

export default function ChartSection() {
  const { t } = useLanguage();
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const dataRef = useRef<MetricsHistory | null>(null);

  const drawChart = useCallback(() => {
    const canvas = canvasRef.current;
    const data = dataRef.current;
    if (!canvas || !data || !data.points || data.points.length < 2) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const rect = canvas.parentElement!.getBoundingClientRect();
    canvas.width = rect.width - 32;
    canvas.height = 250;

    const w = canvas.width;
    const h = canvas.height;
    const padding = { top: 20, right: 20, bottom: 30, left: 50 };
    const drawW = w - padding.left - padding.right;
    const drawH = h - padding.top - padding.bottom;

    const points = data.points;
    const cpuData = points.map((p) => p.cpu_percent || 0);
    const memData = points.map((p) =>
      p.memory ? (p.memory.used / p.memory.total) * 100 : 0
    );
    const diskData = points.map((p) =>
      p.disk ? parseFloat(p.disk.percent) : 0
    );
    const loadData = points.map((p) =>
      p.load_average ? p.load_average['1min'] * 50 : 0  // scale: load 2.0 = 100%
    );

    // Read theme colors from CSS custom properties so the chart
    // responds to dark/light theme changes (fixes #407)
    const styles = getComputedStyle(document.documentElement);
    const bgCard = styles.getPropertyValue('--bg-card').trim() || '#141820';
    const borderColor = styles.getPropertyValue('--border').trim() || '#2a2e34';
    const textDim = styles.getPropertyValue('--text-dim').trim() || '#6b7280';
    const colorBlue = styles.getPropertyValue('--blue').trim() || '#61afef';
    const colorYellow = styles.getPropertyValue('--yellow').trim() || '#e5c07b';
    const colorCyan = styles.getPropertyValue('--cyan').trim() || '#56b6c2';
    const colorPurple = styles.getPropertyValue('--purple').trim() || '#c678dd';

    // Clear
    ctx.fillStyle = bgCard;
    ctx.fillRect(0, 0, w, h);

    // Grid
    ctx.strokeStyle = borderColor;
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = padding.top + (drawH / 4) * i;
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(w - padding.right, y);
      ctx.stroke();

      ctx.fillStyle = textDim;
      ctx.font = '10px JetBrains Mono';
      ctx.textAlign = 'right';
      ctx.fillText(`${100 - i * 25}%`, padding.left - 8, y + 4);
    }

    function drawLine(lineData: number[], color: string, alpha = 1.0) {
      if (lineData.length < 2) return;
      ctx!.strokeStyle = color;
      ctx!.lineWidth = alpha < 1 ? 1.5 : 2;
      ctx!.globalAlpha = alpha;
      ctx!.beginPath();
      for (let i = 0; i < lineData.length; i++) {
        const x = padding.left + (i / (lineData.length - 1)) * drawW;
        const y = padding.top + drawH - (Math.min(lineData[i], 100) / 100) * drawH;
        if (i === 0) ctx!.moveTo(x, y);
        else ctx!.lineTo(x, y);
      }
      ctx!.stroke();
      ctx!.globalAlpha = 1.0;
    }

    drawLine(diskData, colorPurple, 0.5);   // purple, faint — slow-moving
    drawLine(loadData, colorCyan, 0.7);     // cyan
    drawLine(cpuData, colorBlue);           // blue
    drawLine(memData, colorYellow);         // yellow

    // Legend
    ctx.font = '11px JetBrains Mono';
    const legends = [
      { label: t('chart_cpu'), color: colorBlue },
      { label: t('chart_memory'), color: colorYellow },
      { label: t('chart_load'), color: colorCyan },
      { label: t('chart_disk'), color: colorPurple },
    ];
    let legendX = padding.left;
    for (const { label, color } of legends) {
      ctx.fillStyle = color;
      ctx.textAlign = 'left';
      ctx.fillText(label, legendX, h - 5);
      legendX += ctx.measureText(label).width + 14;
    }

    // Time labels
    if (points.length > 0) {
      ctx.fillStyle = textDim;
      ctx.font = '10px JetBrains Mono';
      ctx.textAlign = 'center';
      const first = new Date(points[0].timestamp);
      const last = new Date(points[points.length - 1].timestamp);
      const fmt = (d: Date) =>
        `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
      ctx.fillText(fmt(first), padding.left, h - 5);
      ctx.fillText(fmt(last), w - padding.right, h - 5);
    }
  }, [t]);

  const fetchData = useCallback(async () => {
    try {
      const resp = await fetch(`${API_BASE}/metrics/recent.json?t=${Date.now()}`);
      if (resp.ok) {
        const raw = await resp.json();
        // recent.json is a flat array; wrap it into MetricsHistory shape
        dataRef.current = { points: Array.isArray(raw) ? raw : [] };
        drawChart();
      }
    } catch (e) {
      console.warn('Failed to fetch chart data:', e);
    }
  }, [drawChart]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 60000);
    return () => clearInterval(interval);
  }, [fetchData]);

  useEffect(() => {
    const handleResize = () => {
      clearTimeout((window as unknown as Record<string, ReturnType<typeof setTimeout>>).__chartResize);
      (window as unknown as Record<string, ReturnType<typeof setTimeout>>).__chartResize = setTimeout(drawChart, 250);
    };
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, [drawChart]);

  return (
    <section>
      <h2>{t('section_charts')}</h2>
      <div className="chart-container">
        <canvas ref={canvasRef} width={800} height={300} />
      </div>
    </section>
  );
}
