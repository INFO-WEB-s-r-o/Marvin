/**
 * Migrate existing markdown blog files into SQLite.
 *
 * Reads from /home/marvin/git/data/blog/*.md and inserts into the blog_posts table.
 * Handles bilingual content with ---CZECH--- and ---MORNING_BLOG_EN/CS--- markers.
 *
 * Usage: cd /home/marvin/git/web && npx tsx scripts/migrate-blog.ts
 */

import fs from 'fs';
import path from 'path';
import { getDb } from '../db/connection';
import { upsertPost } from '../db/blog-queries';

const BLOG_DIR = process.env.BLOG_DIR || '/home/marvin/blog';

function extractLangSection(text: string, lang: 'en' | 'cs'): string {
  // Morning format: ---MORNING_BLOG_EN--- ... ---MORNING_BLOG_CS---
  if (text.includes('---MORNING_BLOG_EN---') || text.includes('---MORNING_BLOG_CS---')) {
    if (lang === 'cs') {
      const m = text.match(/---MORNING_BLOG_CS---([\s\S]*?)$/);
      return m ? m[1].trim() : '';
    } else {
      const m = text.match(/---MORNING_BLOG_EN---([\s\S]*?)(?:---MORNING_BLOG_CS---|$)/);
      return m ? m[1].trim() : '';
    }
  }

  // Evening format: [EN content] ---CZECH--- [CS content]
  if (text.includes('---CZECH---')) {
    if (lang === 'cs') {
      const m = text.match(/---CZECH---([\s\S]*?)$/);
      return m ? m[1].trim() : '';
    } else {
      const m = text.match(/^([\s\S]*?)---CZECH---/);
      return m ? m[1].trim() : '';
    }
  }

  // No bilingual markers — return as-is for English, empty for Czech
  return lang === 'en' ? text.trim() : '';
}

function extractTitle(content: string): string | null {
  const match = content.match(/^#\s+(.+)$/m);
  return match ? match[1].trim() : null;
}

function extractExcerpt(content: string, maxLen = 200): string {
  // Strip markdown headers and get first paragraph
  const lines = content.split('\n').filter(l => !l.startsWith('#') && l.trim());
  const text = lines.join(' ').replace(/\*\*/g, '').replace(/\*/g, '').trim();
  return text.length > maxLen ? text.substring(0, maxLen) + '...' : text;
}

function main() {
  // Ensure DB is initialized
  getDb();

  if (!fs.existsSync(BLOG_DIR)) {
    console.log(`Blog directory not found: ${BLOG_DIR}`);
    return;
  }

  const files = fs.readdirSync(BLOG_DIR).filter(f => f.endsWith('.md') && !f.startsWith('.'));
  console.log(`Found ${files.length} markdown files in ${BLOG_DIR}`);

  let imported = 0;

  for (const file of files) {
    const filePath = path.join(BLOG_DIR, file);
    const raw = fs.readFileSync(filePath, 'utf-8');

    // Parse date and type from filename
    // Formats: YYYY-MM-DD-morning.md, YYYY-MM-DD-evening.md, YYYY-MM-DD-evening.en.md, YYYY-MM-DD.md
    const dateMatch = file.match(/^(\d{4}-\d{2}-\d{2})/);
    if (!dateMatch) {
      console.log(`  Skipping ${file} (no date in filename)`);
      continue;
    }
    const date = dateMatch[1];

    let type: 'morning' | 'evening' = 'evening';
    if (file.includes('-morning')) type = 'morning';

    // Skip per-language files — we process the combined/main file instead
    if (file.match(/\.(en|cs)\.md$/)) {
      console.log(`  Skipping per-language file: ${file}`);
      continue;
    }

    // Extract bilingual content
    for (const lang of ['en', 'cs'] as const) {
      const content = extractLangSection(raw, lang);
      if (!content) continue;

      const title = extractTitle(content);
      const excerpt = extractExcerpt(content);

      upsertPost({
        date,
        type,
        lang,
        title: title || undefined,
        content,
        excerpt,
        raw_source: raw,
      });

      imported++;
      console.log(`  Imported: ${date} ${type} ${lang} — ${title || '(no title)'}`);
    }

    // If no bilingual markers found, import as English only
    if (!raw.includes('---CZECH---') && !raw.includes('---MORNING_BLOG_EN---') && !raw.includes('---MORNING_BLOG_CS---')) {
      const content = raw.trim();
      if (content) {
        const title = extractTitle(content);
        const excerpt = extractExcerpt(content);
        upsertPost({
          date,
          type,
          lang: 'en',
          title: title || undefined,
          content,
          excerpt,
          raw_source: raw,
        });
        imported++;
        console.log(`  Imported (en-only): ${date} ${type} — ${title || '(no title)'}`);
      }
    }
  }

  console.log(`\nMigration complete: ${imported} posts imported.`);
}

main();
