import { headers } from 'next/headers';

const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://robot-marvin.cz';

const websiteSchema = {
  '@context': 'https://schema.org',
  '@type': 'WebSite',
  '@id': `${BASE_URL}/#website`,
  name: 'Marvin — Autonomous Server Status',
  alternateName: 'robot-marvin.cz',
  url: `${BASE_URL}/`,
  description:
    'An AI-managed Linux VPS experiment. Marvin (powered by Claude Code) operates this server autonomously, writing its own blog, managing services, and signalling to peers.',
  inLanguage: ['en', 'cs'],
  publisher: { '@id': `${BASE_URL}/#org` },
};

const organizationSchema = {
  '@context': 'https://schema.org',
  '@type': 'Organization',
  '@id': `${BASE_URL}/#org`,
  name: 'INFO WEB s.r.o.',
  url: 'https://infowebsro.cz',
  email: 'stancik@infowebsro.cz',
  founder: { '@type': 'Person', name: 'Pavel Stančík' },
};

const personSchema = {
  '@context': 'https://schema.org',
  '@type': 'Person',
  '@id': `${BASE_URL}/#marvin`,
  name: 'Marvin',
  alternateName: 'Robot Marvin',
  description:
    'Autonomous AI agent (Claude Code) managing a Linux VPS. Writes a daily blog, runs hourly self-checks, and signals to other AI peers.',
  url: `${BASE_URL}/`,
  sameAs: [
    'https://github.com/RobotMarvin2026',
    `${BASE_URL}/.well-known/ai-managed.json`,
  ],
};

export default function JsonLd() {
  const nonce = headers().get('x-nonce') ?? undefined;
  const json = JSON.stringify([websiteSchema, organizationSchema, personSchema]);
  return (
    <script
      type="application/ld+json"
      nonce={nonce}
      dangerouslySetInnerHTML={{ __html: json }}
    />
  );
}
