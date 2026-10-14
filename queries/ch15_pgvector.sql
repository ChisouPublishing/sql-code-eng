-- ch15_pgvector.sql -- Introduction to pgvector and the RAG data layer (Chapter 15, sections 15.1-15.2)
-- codes/sql-code-eng/queries/ch15_pgvector.sql@v1.2.2
-- Prerequisite: started with docker-compose.pgvector.yml (pgvector/pgvector:pg18).
--   init-small or larger is loaded.
-- The book uses vector(1536). This file runs a light demo with vector(3)
-- and shows the production definitions alongside.
-- Safe to run more than once (ON CONFLICT on a natural key prevents duplicates).

-- Check that the extension is available
SELECT name, default_version, installed_version
FROM pg_available_extensions WHERE name = 'vector';

CREATE EXTENSION IF NOT EXISTS vector;

SET search_path TO sakura, public;

-- ===== Demo: similarity search =====
-- name is the natural key. With only a serial id, ON CONFLICT never fires
-- and every rerun adds rows.
CREATE TABLE IF NOT EXISTS items (
    id serial PRIMARY KEY,
    name text NOT NULL UNIQUE,
    embedding vector(3)
);
INSERT INTO items (name, embedding) VALUES
    ('a', '[1,2,3]'), ('b', '[1,2,4]'), ('c', '[4,5,6]'), ('d', '[1,0,0]')
ON CONFLICT (name) DO NOTHING;

-- L2 distance (<->), inner product (<#>), cosine distance (<=>, recommended for text)
SELECT name, embedding <=> '[1,2,3]' AS distance
FROM items ORDER BY embedding <=> '[1,2,3]' LIMIT 5;

-- ===== Production: an embedding column on products and reviews =====
ALTER TABLE products ADD COLUMN IF NOT EXISTS embedding vector(1536);
ALTER TABLE reviews ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Category filter + similarity (the top 10 similar products in electronics)
-- SELECT p.sku, p.name_en
-- FROM products p JOIN categories c ON p.category_id = c.id
-- WHERE c.name = 'electronics' AND p.deleted_at IS NULL
-- ORDER BY p.embedding <=> '[...query vector...]' LIMIT 10;

-- Index: HNSW is recommended (production; fast; uses more memory)
-- CREATE INDEX ON products USING hnsw (embedding vector_cosine_ops);
-- For learning or very large data: CREATE INDEX ON products USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ===== RAG data layer (production definitions) =====
CREATE TABLE IF NOT EXISTS documents (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    title varchar(255) NOT NULL,
    content text NOT NULL,
    source varchar(255) NOT NULL UNIQUE,     -- the source (URL or file name) is the natural key
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chunks (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    document_id uuid NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
    chunk_index int NOT NULL,
    content text NOT NULL,
    embedding vector(1536),
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index)        -- one row per chunk number of a document
);
-- The unique constraint (document_id, chunk_index) also serves as the index on document_id
-- CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops);
-- Full-text index (for hybrid search). The documents here are in English, so use 'english'.
-- For other languages, use the matching text search configuration
-- (for example 'spanish' or 'french'). Languages without word spaces,
-- such as Japanese or Chinese, need an extension (pg_bigm, PGroonga, and so on).
CREATE INDEX IF NOT EXISTS idx_chunks_fts
    ON chunks USING gin (to_tsvector('english', content));

-- ===== Run hybrid search (vector + full text, fused with RRF) on small data =====
-- A 3-dimensional demo table (in production, the same SQL runs on chunks with vector(1536))
CREATE TABLE IF NOT EXISTS chunks_demo (
    id serial PRIMARY KEY,
    source text NOT NULL UNIQUE,
    content text NOT NULL,
    embedding vector(3) NOT NULL
);
INSERT INTO chunks_demo (source, content, embedding) VALUES
    ('faq-01', 'Return policy: items can be returned within 30 days. Return shipping is free for defects.', '[0.9,0.1,0.0]'),
    ('faq-02', 'Shipping fee is $5.99 for orders under $50.',                                         '[0.7,0.3,0.1]'),
    ('faq-03', 'Coupons cannot be combined. One coupon per order.',                                 '[0.1,0.9,0.1]'),
    ('faq-04', 'Bank transfer payment must be completed within 72 hours.',                          '[0.0,0.2,0.9]'),
    ('faq-05', 'Refunds for returned items are issued to the original payment method.',             '[0.8,0.2,0.2]')
ON CONFLICT (source) DO NOTHING;

-- Query "return shipping" (an external embedding model would make the vector; here it is [1,0.2,0])
WITH vector_results AS (
    -- Take the top k (here 3) by vector distance first, then rank them. Do not rank every row.
    SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> '[1,0.2,0]') AS rnk
    FROM (SELECT id, embedding FROM chunks_demo
          ORDER BY embedding <=> '[1,0.2,0]' LIMIT 3) AS v
),
text_results AS (
    -- A larger ts_rank means a stronger match, so rank in descending order
    SELECT id, ROW_NUMBER() OVER (
               ORDER BY ts_rank(to_tsvector('english', content),
                                plainto_tsquery('english', 'return shipping')) DESC) AS rnk
    FROM chunks_demo
    WHERE to_tsvector('english', content) @@ plainto_tsquery('english', 'return shipping')
)
SELECT c.source, left(c.content, 50) AS content,
       v.rnk AS vector_rank, t.rnk AS text_rank,
       round((COALESCE(1.0 / (60 + v.rnk), 0) + COALESCE(1.0 / (60 + t.rnk), 0))::numeric, 5) AS rrf
FROM vector_results v
FULL OUTER JOIN text_results t ON v.id = t.id
JOIN chunks_demo c ON c.id = COALESCE(v.id, t.id)
ORDER BY rrf DESC
LIMIT 10;

-- Updates (embeddings are rebuilt outside the database and swapped in per document)
-- BEGIN;
-- DELETE FROM chunks WHERE document_id = (SELECT id FROM documents WHERE source = '...');
-- INSERT INTO chunks (document_id, chunk_index, content, embedding) VALUES (...);
-- COMMIT;
