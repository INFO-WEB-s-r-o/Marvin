import { NextResponse } from 'next/server';
import { upsertPost } from '@/db/blog-queries';

export const dynamic = 'force-dynamic';

const SECRET = process.env.BLOG_INSERT_SECRET;
if (!SECRET) {
  console.error('FATAL: BLOG_INSERT_SECRET env var is required');
}

export async function POST(request: Request) {
  if (!SECRET) {
    return NextResponse.json({ error: 'Server misconfigured' }, { status: 500 });
  }

  const authHeader = request.headers.get('authorization');
  if (authHeader !== `Bearer ${SECRET}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  try {
    const body = await request.json();
    const { date, type, lang, title, content, excerpt, raw_source } = body;

    if (!date || !type || !lang || !content) {
      return NextResponse.json(
        { error: 'Missing required fields: date, type, lang, content' },
        { status: 400 }
      );
    }

    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      return NextResponse.json({ error: 'Invalid date format, expected YYYY-MM-DD' }, { status: 400 });
    }

    if (!['morning', 'evening'].includes(type)) {
      return NextResponse.json({ error: 'type must be morning or evening' }, { status: 400 });
    }

    if (!['en', 'cs'].includes(lang)) {
      return NextResponse.json({ error: 'lang must be en or cs' }, { status: 400 });
    }

    upsertPost({ date, type, lang, title, content, excerpt, raw_source });
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }
}
