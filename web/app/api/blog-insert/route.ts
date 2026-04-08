import { NextResponse } from 'next/server';
import { timingSafeEqual } from 'crypto';
import { upsertPost } from '@/db/blog-queries';

export const dynamic = 'force-dynamic';

const MAX_BODY_SIZE = 1024 * 1024; // 1MB

const SECRET = process.env.BLOG_INSERT_SECRET;
if (!SECRET) {
  throw new Error('FATAL: BLOG_INSERT_SECRET env var is required — set it before starting the server');
}

export async function POST(request: Request) {
  if (!SECRET) {
    return NextResponse.json({ error: 'Server misconfigured' }, { status: 500 });
  }

  const contentLength = parseInt(request.headers.get('content-length') || '0', 10);
  if (contentLength > MAX_BODY_SIZE) {
    return NextResponse.json({ error: 'Request body too large' }, { status: 413 });
  }

  const authHeader = request.headers.get('authorization') || '';
  const expected = Buffer.from(`Bearer ${SECRET}`);
  const actual = Buffer.from(authHeader);
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
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

    await upsertPost({ date, type, lang, title, content, excerpt, raw_source });
    return NextResponse.json({ ok: true });
  } catch (e) {
    return NextResponse.json({ error: 'Invalid request body' }, { status: 400 });
  }
}
