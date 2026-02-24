'use client';

import { useState, useEffect, useCallback } from 'react';
import { useLanguage } from './LanguageProvider';
import BlogCalendar from './BlogCalendar';
import BlogPost from './BlogPost';
import type { BlogPostData } from '@/lib/types';

export default function BlogSection() {
  const { lang, t } = useLanguage();
  const [selectedDate, setSelectedDate] = useState<string | null>(null);
  const [posts, setPosts] = useState<BlogPostData[]>([]);
  const [activeType, setActiveType] = useState<'morning' | 'evening'>('evening');
  const [loading, setLoading] = useState(false);
  const [latestDate, setLatestDate] = useState<string | null>(null);

  // On mount, find the latest date with posts
  useEffect(() => {
    fetch('/api/blog')
      .then(r => r.json())
      .then(data => {
        if (data.dates && data.dates.length > 0) {
          const latest = data.dates[0]; // Already sorted descending
          setLatestDate(latest);
          setSelectedDate(latest);
        }
      })
      .catch(() => {});
  }, []);

  const fetchPosts = useCallback(async (date: string) => {
    setLoading(true);
    try {
      const resp = await fetch(`/api/blog/${date}?lang=${lang}`);
      if (resp.ok) {
        const data = await resp.json();
        setPosts(data.posts || []);
        // Auto-select the latest type available
        if (data.posts && data.posts.length > 0) {
          const hasEvening = data.posts.some((p: BlogPostData) => p.type === 'evening');
          setActiveType(hasEvening ? 'evening' : 'morning');
        }
      }
    } catch (e) {
      console.warn('Failed to fetch blog posts:', e);
      setPosts([]);
    }
    setLoading(false);
  }, [lang]);

  useEffect(() => {
    if (selectedDate) {
      fetchPosts(selectedDate);
    }
  }, [selectedDate, fetchPosts]);

  const handleDateSelect = (date: string) => {
    setSelectedDate(date);
  };

  const morningPost = posts.find(p => p.type === 'morning');
  const eveningPost = posts.find(p => p.type === 'evening');
  const currentPost = activeType === 'morning' ? morningPost : eveningPost;

  return (
    <section>
      <h2>{t('section_blog')}</h2>
      <BlogCalendar onDateSelect={handleDateSelect} selectedDate={selectedDate} />

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
        <div className="blog-box">
          <p className="muted">{t('blog_loading')}</p>
        </div>
      ) : currentPost ? (
        <BlogPost post={currentPost} />
      ) : selectedDate ? (
        <div className="blog-box">
          <p className="muted">{t('blog_no_post')}</p>
        </div>
      ) : (
        <div className="blog-box">
          <p className="muted">{t('blog_empty')}</p>
        </div>
      )}
    </section>
  );
}
