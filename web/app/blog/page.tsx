'use client';

import TerminalHeader from '../components/TerminalHeader';
import BlogCalendar from '../components/BlogCalendar';
import BlogPost from '../components/BlogPost';
import { useLanguage } from '../components/LanguageProvider';
import { useState, useEffect, useCallback } from 'react';
import type { BlogPostData } from '@/lib/types';
import Link from 'next/link';

export default function BlogPage() {
  const { lang, t } = useLanguage();
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [posts, setPosts] = useState<BlogPostData[]>([]);
  const [activeType, setActiveType] = useState<'morning' | 'evening'>('evening');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    fetch('/api/blog', { cache: 'no-store' })
      .then(r => r.json())
      .then(data => {
        if (data.dates && data.dates.length > 0) {
          setSelectedDate(data.dates[0]);
        }
      })
      .catch(() => {});
  }, []);

  const fetchPosts = useCallback(async (date: string) => {
    setLoading(true);
    try {
      const resp = await fetch(`/api/blog/${date}?lang=${lang}`, { cache: 'no-store' });
      if (resp.ok) {
        const data = await resp.json();
        setPosts(data.posts || []);
        if (data.posts && data.posts.length > 0) {
          const hasEvening = data.posts.some((p: BlogPostData) => p.type === 'evening');
          setActiveType(hasEvening ? 'evening' : 'morning');
        }
      }
    } catch {
      setPosts([]);
    }
    setLoading(false);
  }, [lang]);

  useEffect(() => {
    if (selectedDate) fetchPosts(selectedDate);
  }, [selectedDate, fetchPosts]);

  const morningPost = posts.find(p => p.type === 'morning');
  const eveningPost = posts.find(p => p.type === 'evening');
  const currentPost = activeType === 'morning' ? morningPost : eveningPost;

  return (
    <div className="terminal">
      <TerminalHeader />
      <div className="terminal-body">
        <div style={{ marginBottom: '1rem' }}>
          <Link href="/" style={{ color: 'var(--green)', textDecoration: 'none', fontSize: '0.85rem' }}>
            ← {t('back_to_dashboard') || 'back to dashboard'}
          </Link>
        </div>

        <section>
          <h2>$ marvin --blog --all</h2>
          <BlogCalendar onDateSelect={setSelectedDate} selectedDate={selectedDate} />

          {selectedDate && posts.length > 0 && (
            <div className="blog-type-tabs">
              {morningPost && (
                <button
                  className={`blog-type-tab ${activeType === 'morning' ? 'active' : ''}`}
                  onClick={() => setActiveType('morning')}
                >
                  {t('blog_morning')}
                </button>
              )}
              {eveningPost && (
                <button
                  className={`blog-type-tab ${activeType === 'evening' ? 'active' : ''}`}
                  onClick={() => setActiveType('evening')}
                >
                  {t('blog_evening')}
                </button>
              )}
            </div>
          )}

          {loading ? (
            <div className="blog-box"><p className="muted">{t('blog_loading')}</p></div>
          ) : currentPost ? (
            <BlogPost post={currentPost} />
          ) : selectedDate ? (
            <div className="blog-box"><p className="muted">{t('blog_no_post')}</p></div>
          ) : (
            <div className="blog-box"><p className="muted">{t('blog_empty')}</p></div>
          )}
        </section>
      </div>
    </div>
  );
}
