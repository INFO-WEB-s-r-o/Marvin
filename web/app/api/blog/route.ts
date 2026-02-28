import { NextResponse } from 'next/server';
import { getDatesWithPosts, getAllDates } from '@/db/blog-queries';

export const dynamic = 'force-dynamic';

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const month = searchParams.get('month');

  if (month) {
    if (!/^\d{4}-\d{2}$/.test(month)) {
      return NextResponse.json({ error: 'Invalid month format, expected YYYY-MM' }, { status: 400 });
    }
    const dates = getDatesWithPosts(month);
    const resp = NextResponse.json({ dates });
    resp.headers.set('Cache-Control', 'no-store, max-age=0');
    return resp;
  }

  // Return all dates
  const dates = getAllDates();
  const resp = NextResponse.json({ dates });
  resp.headers.set('Cache-Control', 'no-store, max-age=0');
  return resp;
}
