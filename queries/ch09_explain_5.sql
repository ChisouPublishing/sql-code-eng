-- ch09_explain_5.sql -- Execution plans of five slow queries and their fixes (Chapter 9)
-- codes/sql-code-eng/queries/ch09_explain_5.sql@v1.2.2
-- Prerequisite: default database sakura_market (small + medium. The small data alone shows little difference).
-- Measure with EXPLAIN (ANALYZE, BUFFERS). Index names here do not overlap with ch10.
SET search_path TO sakura, public;

-- Q1: filter by rank (Seq Scan -> partial index)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, display_name FROM users WHERE rank = 'gold' LIMIT 100;
-- Fix
CREATE INDEX IF NOT EXISTS idx_ch09_users_gold ON users (id) WHERE rank = 'gold';
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, display_name FROM users WHERE rank = 'gold' LIMIT 100;

-- Q2: join orders and users (Seq Scan on users -> filter first with an index on rank)
-- The join column orders.user_id already has the base index idx_orders_user (03_indexes.sql).
-- Up to v1.1.1 this file created idx_ch09_orders_user on the same column.
-- That gives two indexes with the same job, which only slows down writes,
-- so v1.2.0 removed it. Check the existing indexes before you create one (Chapter 10).
SELECT indexname, indexdef FROM pg_indexes
WHERE schemaname = 'sakura' AND tablename = 'orders' AND indexdef LIKE '%(user_id)%';
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, u.display_name, o.amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE u.rank = 'platinum' LIMIT 100;
-- Fix
CREATE INDEX IF NOT EXISTS idx_ch09_users_rank ON users (rank);
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, u.display_name, o.amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE u.rank = 'platinum' LIMIT 100;

-- Q3: latest 10 rows (Seq Scan + Sort -> Index Scan Backward on an ordered index)
-- The latest 10 rows of the behavior log (about 1 million rows).
-- Without an index on created_at, PostgreSQL reads and sorts every row.
-- Note: newest orders first (orders.ordered_at) already uses the base index idx_orders_ordered_at.
--   A B-tree can be read backward (Index Scan Backward),
--   so you do not need a separate DESC index.
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, action, created_at FROM behavior_logs ORDER BY created_at DESC LIMIT 10;
-- Fix
CREATE INDEX IF NOT EXISTS idx_ch09_behavior_created ON behavior_logs (created_at);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, action, created_at FROM behavior_logs ORDER BY created_at DESC LIMIT 10;

-- Q4: N+1 (order count per user, one query per user -> one JOIN)
-- What the bad pattern looks like (the application sends this 100 times):
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders WHERE user_id = (SELECT id FROM users LIMIT 1);
-- Fix (100 users at once)
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.id, count(o.id) AS orders
FROM (SELECT id FROM users LIMIT 100) u
LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id;

-- Q5: sales by category with four joins (HashAggregate over many rows ->
-- move the aggregation into a materialized view; see Chapters 12 and 14)
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name, SUM(oi.quantity * oi.price) AS sales
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name;

-- What to read: cost (startup..total), estimated rows versus actual rows (a large gap -> ANALYZE),
-- Buffers: hit/read, loops, Heap Fetches.
-- Paste this output to the AI as is (Chapter 9, section 9.6).
