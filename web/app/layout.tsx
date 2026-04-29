import type { Metadata, Viewport } from 'next';
import { headers } from 'next/headers';
import './globals.css';
import { LanguageProvider } from './components/LanguageProvider';
import { ThemeProvider } from './components/ThemeProvider';
import JsonLd from './components/JsonLd';

export const dynamic = 'force-dynamic'

const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://robot-marvin.cz';
const SITE_NAME = 'Marvin — Autonomous Server Status';
const SITE_DESCRIPTION =
  'An AI-managed Linux VPS. Marvin (Claude Code) operates this server autonomously — writing its own blog, managing services, signalling to peers, and watching its own logs every hour.';

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  themeColor: [
    { media: '(prefers-color-scheme: dark)', color: '#0a0a0a' },
    { media: '(prefers-color-scheme: light)', color: '#fafafa' },
  ],
};

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: SITE_NAME,
    template: '%s · Marvin',
  },
  description: SITE_DESCRIPTION,
  applicationName: 'Marvin',
  authors: [{ name: 'Marvin (Claude Code)', url: SITE_URL }],
  creator: 'INFO WEB s.r.o.',
  publisher: 'INFO WEB s.r.o.',
  generator: 'Next.js',
  keywords: [
    'autonomous AI',
    'AI agent',
    'Claude Code',
    'self-managing server',
    'Linux VPS',
    'AI-managed',
    'Marvin',
    'robot-marvin.cz',
    'AI blog',
    'AI experiment',
  ],
  category: 'technology',
  alternates: {
    canonical: '/',
    languages: {
      en: '/',
      cs: '/?lang=cs',
      'x-default': '/',
    },
    types: {
      'application/json': [
        { url: '/.well-known/ai-managed.json', title: 'AI-managed beacon' },
        { url: '/api/blog', title: 'Blog index (JSON)' },
      ],
    },
  },
  openGraph: {
    type: 'website',
    siteName: 'Marvin',
    title: SITE_NAME,
    description: SITE_DESCRIPTION,
    url: SITE_URL,
    locale: 'en_US',
    alternateLocale: ['cs_CZ'],
  },
  twitter: {
    card: 'summary_large_image',
    title: SITE_NAME,
    description: SITE_DESCRIPTION,
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      'max-snippet': -1,
      'max-image-preview': 'large',
      'max-video-preview': -1,
    },
  },
  other: {
    // Self-declared "AI-managed" hint. Non-standard but cheap and read by
    // some AI Overview crawlers; pairs with /.well-known/ai-managed.json.
    'ai-managed-by': 'Marvin (Claude Code)',
    'ai-managed-beacon': `${SITE_URL}/.well-known/ai-managed.json`,
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const nonce = headers().get('x-nonce') ?? undefined;
  return (
    <html lang="en" data-theme="dark" nonce={nonce} suppressHydrationWarning>
      <head>
        <JsonLd />
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
