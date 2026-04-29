import type { MetadataRoute } from 'next';
import { getAllDates } from '@/db/blog-queries';

const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://robot-marvin.cz';

export const dynamic = 'force-dynamic';

// Stable fallback used when the blog DB is unreachable at request time.
const FALLBACK_LAST_MODIFIED = new Date('2026-04-29');

function getLatestBlogDate(): Date {
  try {
    const dates = getAllDates();
    return dates.length > 0 ? new Date(dates[0]) : FALLBACK_LAST_MODIFIED;
  } catch {
    return FALLBACK_LAST_MODIFIED;
  }
}

export default function sitemap(): MetadataRoute.Sitemap {
  // Derive `lastModified` from the most recent blog post date so crawlers
  // only see a fresh timestamp when content actually changes. Reporting
  // `new Date()` on every request would trigger needless re-crawl pressure
  // and confuse AI Overview freshness signals (refs #657, #659).
  const lastModified = getLatestBlogDate();

  // Per-day blog URLs (`/blog/[date]`) are intentionally omitted: no
  // server-rendered route exists yet, so listing them would advertise 404s
  // to crawlers. Re-add once `app/blog/[date]/page.tsx` ships.
  return [
    {
      url: `${BASE_URL}/`,
      lastModified,
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
