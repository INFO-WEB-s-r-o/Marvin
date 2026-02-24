import { getDb } from './connection';

export interface BlogPost {
  id: number;
  date: string;
  type: 'morning' | 'evening';
  lang: string;
  title: string | null;
  content: string;
  excerpt: string | null;
  created_at: string;
  updated_at: string;
}

/** Get all dates that have blog posts for a given month (YYYY-MM) */
export function getDatesWithPosts(month: string): string[] {
  const db = getDb();
  const rows = db.prepare(
    `SELECT DISTINCT date FROM blog_posts WHERE date LIKE ? ORDER BY date`
  ).all(`${month}%`) as { date: string }[];
  return rows.map(r => r.date);
}

/** Get morning & evening posts for a specific date and language */
export function getPostsForDate(date: string, lang: string): BlogPost[] {
  const db = getDb();
  return db.prepare(
    `SELECT * FROM blog_posts WHERE date = ? AND lang = ? ORDER BY type`
  ).all(date, lang) as BlogPost[];
}

/** Insert or update a blog post */
export function upsertPost(post: {
  date: string;
  type: 'morning' | 'evening';
  lang: string;
  title?: string;
  content: string;
  excerpt?: string;
  raw_source?: string;
}): void {
  const db = getDb();
  db.prepare(`
    INSERT INTO blog_posts (date, type, lang, title, content, excerpt, raw_source)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(date, type, lang) DO UPDATE SET
      title = excluded.title,
      content = excluded.content,
      excerpt = excluded.excerpt,
      raw_source = excluded.raw_source,
      updated_at = datetime('now')
  `).run(post.date, post.type, post.lang, post.title || null, post.content, post.excerpt || null, post.raw_source || null);
}

/** Get all unique dates with posts, ordered descending */
export function getAllDates(): string[] {
  const db = getDb();
  const rows = db.prepare(
    `SELECT DISTINCT date FROM blog_posts ORDER BY date DESC`
  ).all() as { date: string }[];
  return rows.map(r => r.date);
}
