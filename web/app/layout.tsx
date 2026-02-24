import type { Metadata } from 'next';
import './globals.css';
import { LanguageProvider } from './components/LanguageProvider';

export const metadata: Metadata = {
  title: 'Marvin — Autonomous Server Status',
  description: 'An AI-managed server experiment. Marvin (Claude Code) runs this VPS autonomously.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <LanguageProvider>
          {children}
        </LanguageProvider>
      </body>
    </html>
  );
}
