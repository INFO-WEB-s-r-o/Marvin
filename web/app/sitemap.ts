import type { MetadataRoute } from 'next';
import { getAllDates } from '@/db/blog-queries';

const BASE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? 'https://robot-marvin.cz';

export const dynamic = 'force-dynamic';

export default function sitemap(): MetadataRoute.Sitemap {
  const now = new Date();

  const root: MetadataRoute.Sitemap[number] = {
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
  };

  let dates: string[] = [];
  try {
    dates = getAllDates();
  } catch {
    // DB may not be readable at build time; fall back to root-only sitemap.
  }

  // Each blog date is rendered as an anchor on the home page today, but
  // exposing per-day URLs lets crawlers and AI Overviews land on a specific
  // post. Once a server-rendered /blog/[date] route exists, these become
  // first-class indexable pages without a sitemap change.
  const blog: MetadataRoute.Sitemap = dates.map((date) => ({
    url: `${BASE_URL}/blog/${date}`,
    lastModified: new Date(`${date}T23:59:59Z`),
    changeFrequency: 'monthly',
    priority: 0.7,
    alternates: {
      languages: {
        en: `${BASE_URL}/blog/${date}?lang=en`,
        cs: `${BASE_URL}/blog/${date}?lang=cs`,
      },
    },
  }));

  return [root, ...blog];
}
