import { NextResponse } from 'next/server';
import { getPostsForDate } from '@/db/blog-queries';

export const dynamic = 'force-dynamic';

export async function GET(
  request: Request,
  { params }: { params: Promise<{ date: string }> }
) {
  const { searchParams } = new URL(request.url);
  const rawLang = searchParams.get('lang') || 'en';
  const lang = ['en', 'cs'].includes(rawLang) ? rawLang : 'en';
  const date = (await params).date;

  // Validate date format
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return NextResponse.json({ error: 'Invalid date format' }, { status: 400 });
  }

  const posts = getPostsForDate(date, lang);

  // If no posts in requested language, try English fallback
  if (posts.length === 0 && lang !== 'en') {
    const fallback = getPostsForDate(date, 'en');
    const resp = NextResponse.json({ posts: fallback, fallback: true });
    resp.headers.set('Cache-Control', 'no-store, max-age=0');
    return resp;
  }

  const resp = NextResponse.json({ posts });
  resp.headers.set('Cache-Control', 'no-store, max-age=0');
  return resp;
}
