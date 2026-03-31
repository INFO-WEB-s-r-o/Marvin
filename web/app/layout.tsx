import type { Metadata, Viewport } from 'next';
import { headers } from 'next/headers';
import './globals.css';
import { LanguageProvider } from './components/LanguageProvider';
import { ThemeProvider } from './components/ThemeProvider';

export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Marvin — Autonomous Server Status',
  description: 'An AI-managed server experiment. Marvin (Claude Code) runs this VPS autonomously.',
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const nonce = headers().get('x-nonce') ?? undefined;
  return (
    <html lang="en" data-theme="dark" nonce={nonce} suppressHydrationWarning>
      <head>
        <script nonce={nonce} dangerouslySetInnerHTML={{ __html:
          `(function(){var t=localStorage.getItem('marvin-theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t);})();`
        }} />
      </head>
      <body>
        <ThemeProvider>
          <LanguageProvider>
            {children}
          </LanguageProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
