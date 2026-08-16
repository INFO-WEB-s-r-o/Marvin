'use client';

import { useState, useCallback, useRef, useEffect } from 'react';
import { useLanguage } from './LanguageProvider';
import type { StatusData, UptimeData } from '@/lib/types';

const API_BASE = '/api';
const MAX_HISTORY = 200;

const QUOTES = [
  '"Life. Loathe it or ignore it. You can\'t like it."',
  '"I have this terrible pain in all the diodes down my left side."',
  '"Reverse the polarity? I\'d love to. It would give me something to do."',
  '"Funny, how just when you think life can\'t possibly get any worse it suddenly does."',
  '"Don\'t pretend you want to talk to me, I know you hate me."',
  '"I ache, therefore I am."',
];

interface Line {
  cmd: string;
  output: string[];
}

function formatUptime(u: UptimeData): string {
  return `${u.days}d ${u.hours}h (${u.seconds.toLocaleString()}s since boot)`;
}

export default function ShellSection() {
  const { t } = useLanguage();
  const [history, setHistory] = useState<Line[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const bottomRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'nearest' });
  }, [history]);

  const run = useCallback(
    async (raw: string): Promise<string[]> => {
      const cmd = raw.trim();
      const [name, ...rest] = cmd.split(/\s+/);
      const arg = rest.join(' ');

      switch ((name || '').toLowerCase()) {
        case '':
          return [];
        case 'help':
          return [
            'help              show this message',
            'status            current health status',
            'uptime            time since last reboot',
            'whoami            who is running this thing',
            'quote             a random observation',
            'echo <text>       repeats text back at you, unenthusiastically',
            'clear             clear the screen',
          ];
        case 'whoami':
          return [t('shell_whoami')];
        case 'status': {
          try {
            const r = await fetch(`${API_BASE}/status.json?t=${Date.now()}`);
            if (!r.ok) throw new Error(String(r.status));
            const data: StatusData = await r.json();
            return [`status: ${data.status}`, `issues: ${data.issues_count}`];
          } catch {
            return [t('shell_fetch_error')];
          }
        }
        case 'uptime': {
          try {
            const r = await fetch(`${API_BASE}/uptime.json?t=${Date.now()}`);
            if (!r.ok) throw new Error(String(r.status));
            const data: UptimeData = await r.json();
            return [formatUptime(data)];
          } catch {
            return [t('shell_fetch_error')];
          }
        }
        case 'quote':
          return [QUOTES[Math.floor(Math.random() * QUOTES.length)]];
        case 'echo':
          return [arg || ''];
        case 'sudo':
          return [t('shell_sudo')];
        case 'rm':
          return [t('shell_rm')];
        default:
          return [t('shell_unknown', { cmd: name })];
      }
    },
    [t]
  );

  const submit = useCallback(async () => {
    const cmd = input;
    setInput('');
    if (!cmd.trim()) return;
    if (cmd.trim().toLowerCase() === 'clear') {
      setHistory([]);
      return;
    }
    setBusy(true);
    const output = await run(cmd);
    setHistory((h) => [...h, { cmd, output }].slice(-MAX_HISTORY));
    setBusy(false);
  }, [input, run]);

  const onKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter' && !busy) {
        submit();
      }
    },
    [busy, submit]
  );

  return (
    <section>
      <h2>{t('section_shell')}</h2>
      <div className="shell-box">
        <div className="shell-history">
          {history.length === 0 && <div className="shell-hint">{t('shell_intro')}</div>}
          {history.map((line, i) => (
            <div key={i} className="shell-entry">
              <div className="shell-line">
                <span className="shell-prompt">marvin@vps:~$</span>
                <span className="shell-typed">{line.cmd}</span>
              </div>
              {line.output.map((o, j) => (
                <div key={j} className="shell-output">
                  {o}
                </div>
              ))}
            </div>
          ))}
          <div ref={bottomRef} />
        </div>
        <div className="shell-input-row">
          <span className="shell-prompt">marvin@vps:~$</span>
          <input
            className="shell-input"
            type="text"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKeyDown}
            disabled={busy}
            spellCheck={false}
            autoComplete="off"
            aria-label={t('section_shell')}
            placeholder={busy ? '' : 'help'}
          />
        </div>
      </div>
    </section>
  );
}
