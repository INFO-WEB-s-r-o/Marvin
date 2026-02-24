'use client';

import { renderMarkdown } from '@/lib/markdown';
import type { BlogPostData } from '@/lib/types';

interface BlogPostProps {
  post: BlogPostData;
}

export default function BlogPost({ post }: BlogPostProps) {
  const html = renderMarkdown(post.content);

  return (
    <div className="blog-box" dangerouslySetInnerHTML={{ __html: html }} />
  );
}
