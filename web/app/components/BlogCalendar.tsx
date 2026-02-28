'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';

interface BlogCalendarProps {
  onDateSelect: (date: string) => void;
  selectedDate: string | null;
}

function pad(n: number): string {
  return String(n).padStart(2, '0');
}

export default function BlogCalendar({ onDateSelect, selectedDate }: BlogCalendarProps) {
  const { t } = useLanguage();
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [month, setMonth] = useState(now.getMonth()); // 0-indexed
  const [datesWithPosts, setDatesWithPosts] = useState<Set<string>>(new Set());

  const monthKey = `${year}-${pad(month + 1)}`;
  const todayStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;

  const fetchDates = useCallback(async () => {
    try {
      const resp = await fetch(`/api/blog?month=${monthKey}`, { cache: 'no-store' });
      if (resp.ok) {
        const data = await resp.json();
        setDatesWithPosts(new Set(data.dates));
      }
    } catch (e) {
      console.warn('Failed to fetch blog dates:', e);
    }
  }, [monthKey]);

  useEffect(() => {
    fetchDates();
  }, [fetchDates]);

  const prevMonth = () => {
    if (month === 0) {
      setYear(y => y - 1);
      setMonth(11);
    } else {
      setMonth(m => m - 1);
    }
  };

  const nextMonth = () => {
    if (month === 11) {
      setYear(y => y + 1);
      setMonth(0);
    } else {
      setMonth(m => m + 1);
    }
  };

  // Build calendar grid
  const firstDay = new Date(year, month, 1);
  const lastDay = new Date(year, month + 1, 0);
  const daysInMonth = lastDay.getDate();
  // Monday=0, Sunday=6
  let startDow = firstDay.getDay() - 1;
  if (startDow < 0) startDow = 6;

  const dayNames = [
    t('calendar_mon'), t('calendar_tue'), t('calendar_wed'),
    t('calendar_thu'), t('calendar_fri'), t('calendar_sat'), t('calendar_sun'),
  ];

  const monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  const cells: Array<{ day: number; dateStr: string } | null> = [];
  for (let i = 0; i < startDow; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) {
    cells.push({ day: d, dateStr: `${year}-${pad(month + 1)}-${pad(d)}` });
  }

  return (
    <div className="blog-calendar">
      <div className="calendar-header">
        <button className="calendar-nav-btn" onClick={prevMonth}>&lt;</button>
        <span className="calendar-title">{monthNames[month]} {year}</span>
        <button className="calendar-nav-btn" onClick={nextMonth}>&gt;</button>
      </div>
      <div className="calendar-grid">
        {dayNames.map(d => (
          <div key={d} className="calendar-dow">{d}</div>
        ))}
        {cells.map((cell, i) => {
          if (!cell) {
            return <div key={`empty-${i}`} className="calendar-day empty" />;
          }
          const hasPosts = datesWithPosts.has(cell.dateStr);
          const isSelected = cell.dateStr === selectedDate;
          const isToday = cell.dateStr === todayStr;

          const classes = [
            'calendar-day',
            hasPosts ? 'has-posts' : '',
            isSelected ? 'selected' : '',
            isToday ? 'today' : '',
          ].filter(Boolean).join(' ');

          return (
            <div
              key={cell.dateStr}
              className={classes}
              onClick={hasPosts ? () => onDateSelect(cell.dateStr) : undefined}
            >
              {cell.day}
            </div>
          );
        })}
      </div>
    </div>
  );
}
