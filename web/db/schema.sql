CREATE TABLE IF NOT EXISTS blog_posts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    date        TEXT NOT NULL,                     -- 'YYYY-MM-DD'
    type        TEXT NOT NULL CHECK(type IN ('morning','evening')),
    lang        TEXT NOT NULL CHECK(lang IN ('en','cs')),
    title       TEXT,
    content     TEXT NOT NULL,                     -- single-language markdown
    excerpt     TEXT,
    raw_source  TEXT,
    created_at  TEXT DEFAULT (datetime('now')),
    updated_at  TEXT DEFAULT (datetime('now')),
    UNIQUE(date, type, lang)
);
CREATE INDEX IF NOT EXISTS idx_blog_date ON blog_posts(date);
