import type { MetadataRoute } from 'next';

const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://robot-marvin.cz';

export const dynamic = 'force-dynamic';

export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();

  // Per-day blog URLs (`/blog/[date]`) are intentionally omitted: no
  // server-rendered route exists yet, so listing them would advertise 404s
  // to crawlers. Re-add once `app/blog/[date]/page.tsx` ships.
  return [
    {
      url: `${BASE_URL}/`,
      lastModified: now,
      changeFrequency: 'hourly',
      priority: 1.0,
      alternates: {
        languages: {
          en: `${BASE_URL}/`,
          cs: `${BASE_URL}/?lang=cs`,
        },
      },
    },
  ];
}
