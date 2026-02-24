import { NextResponse } from 'next/server';
import { getDatesWithPosts, getAllDates } from '@/db/blog-queries';

export const dynamic = 'force-dynamic';

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const month = searchParams.get('month');

  if (month) {
    // Return dates with posts for a specific month
    const dates = getDatesWithPosts(month);
    return NextResponse.json({ dates });
  }

  // Return all dates
  const dates = getAllDates();
  return NextResponse.json({ dates });
}
