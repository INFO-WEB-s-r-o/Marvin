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

    // Clear
    ctx.fillStyle = '#141820';
    ctx.fillRect(0, 0, w, h);

    // Grid
    ctx.strokeStyle = '#2a2e34';
    ctx.lineWidth = 1;
    for (let i = 0; i <= 4; i++) {
      const y = padding.top + (drawH / 4) * i;
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(w - padding.right, y);
      ctx.stroke();

      ctx.fillStyle = '#6b7280';
      ctx.font = '10px JetBrains Mono';
      ctx.textAlign = 'right';
      ctx.fillText(`${100 - i * 25}%`, padding.left - 8, y + 4);
    }

    function drawLine(lineData: number[], color: string) {
      if (lineData.length < 2) return;
      ctx!.strokeStyle = color;
      ctx!.lineWidth = 2;
      ctx!.beginPath();
      for (let i = 0; i < lineData.length; i++) {
        const x = padding.left + (i / (lineData.length - 1)) * drawW;
        const y = padding.top + drawH - (lineData[i] / 100) * drawH;
        if (i === 0) ctx!.moveTo(x, y);
        else ctx!.lineTo(x, y);
      }
      ctx!.stroke();
    }

    drawLine(cpuData, '#61afef');
    drawLine(memData, '#e5c07b');

    // Legend
    ctx.font = '11px JetBrains Mono';
    ctx.fillStyle = '#61afef';
    ctx.textAlign = 'left';
    ctx.fillText(t('chart_cpu'), padding.left, h - 5);
    ctx.fillStyle = '#e5c07b';
    ctx.fillText(t('chart_memory'), padding.left + 80, h - 5);

    // Time labels
    if (points.length > 0) {
      ctx.fillStyle = '#6b7280';
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
      const resp = await fetch(`${API_BASE}/metrics-history.json?t=${Date.now()}`);
      if (resp.ok) {
        dataRef.current = await resp.json();
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
        {dataRef.current && dataRef.current.points && dataRef.current.points.length >= 2 ? (
          <canvas ref={canvasRef} width={800} height={300} />
        ) : (
          <canvas ref={canvasRef} width={800} height={300} />
        )}
      </div>
    </section>
  );
}
