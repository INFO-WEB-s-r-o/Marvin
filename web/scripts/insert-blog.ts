/**
 * CLI tool for inserting blog posts into SQLite.
 * Used by agent scripts (morning-check.sh, evening-report.sh).
 *
 * Usage:
 *   npx tsx scripts/insert-blog.ts --date 2026-02-24 --type morning --lang en --content "..."
 *   npx tsx scripts/insert-blog.ts --date 2026-02-24 --type evening --file /path/to/post.md
 *   npx tsx scripts/insert-blog.ts --date 2026-02-24 --type evening --file /path/to/combined.md --bilingual
 */

import fs from 'fs';
import { getDb } from '../db/connection';
import { upsertPost } from '../db/blog-queries';

function extractLangSection(text: string, lang: 'en' | 'cs'): string {
  if (text.includes('---MORNING_BLOG_EN---') || text.includes('---MORNING_BLOG_CS---')) {
    if (lang === 'cs') {
      const m = text.match(/---MORNING_BLOG_CS---([\s\S]*?)$/);
      return m ? m[1].trim() : '';
    } else {
      const m = text.match(/---MORNING_BLOG_EN---([\s\S]*?)(?:---MORNING_BLOG_CS---|$)/);
      return m ? m[1].trim() : '';
    }
  }
  if (text.includes('---CZECH---')) {
    if (lang === 'cs') {
      const m = text.match(/---CZECH---([\s\S]*?)$/);
      return m ? m[1].trim() : '';
    } else {
      const m = text.match(/^([\s\S]*?)---CZECH---/);
      return m ? m[1].trim() : '';
    }
  }
  return lang === 'en' ? text.trim() : '';
}

function extractTitle(content: string): string | null {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? match[1].trim() : null;
}

function extractExcerpt(content: string, maxLen = 200): string {
  const lines = content.split('\n').filter(l => !l.startsWith('#') && l.trim());
  const text = lines.join(' ').replace(/\*\*/g, '').replace(/\*/g, '').trim();
  return text.length > maxLen ? text.substring(0, maxLen) + '...' : text;
}

function main() {
  const args = process.argv.slice(2);
  const flags: Record<string, string> = {};

  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length && !args[i + 1].startsWith('--')) {
      flags[args[i].slice(2)] = args[i + 1];
      i++;
    } else if (args[i] === '--bilingual') {
      flags.bilingual = 'true';
    }
  }

  const date = flags.date;
  const type = flags.type as 'morning' | 'evening';

  if (!date || !type) {
    console.error('Usage: insert-blog.ts --date YYYY-MM-DD --type morning|evening [--lang en|cs] [--content "..."] [--file path] [--bilingual]');
    process.exit(1);
  }

  // Ensure DB is initialized
  getDb();

  let rawContent = '';
  if (flags.file) {
    if (!fs.existsSync(flags.file)) {
      console.error(`File not found: ${flags.file}`);
      process.exit(1);
    }
    rawContent = fs.readFileSync(flags.file, 'utf-8');
  } else if (flags.content) {
    rawContent = flags.content;
  } else {
    // Read from stdin
    rawContent = fs.readFileSync('/dev/stdin', 'utf-8');
  }

  if (flags.bilingual === 'true') {
    // Split bilingual content and insert both languages
    for (const lang of ['en', 'cs'] as const) {
      const content = extractLangSection(rawContent, lang);
      if (!content) continue;

      upsertPost({
        date,
        type,
        lang,
        title: extractTitle(content) || undefined,
        content,
        excerpt: extractExcerpt(content),
        raw_source: rawContent,
      });
      console.log(`Inserted: ${date} ${type} ${lang}`);
    }
  } else {
    const lang = (flags.lang || 'en') as 'en' | 'cs';
    upsertPost({
      date,
      type,
      lang,
      title: extractTitle(rawContent) || undefined,
      content: rawContent.trim(),
      excerpt: extractExcerpt(rawContent),
      raw_source: rawContent,
    });
    console.log(`Inserted: ${date} ${type} ${lang}`);
  }
}

main();
