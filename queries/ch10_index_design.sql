-- ch10_index_design.sql -- Index design and optimization (Chapter 10)
-- codes/sql-code-eng/queries/ch10_index_design.sql@v1.2.2
-- Prerequisite: benchmark database sakura_xl (10 million orders, 10 million behavior log rows).
--   psql -d sakura_xl -f queries/ch10_index_design.sql
--   It also runs on the default database (sakura_market, about 100,000 rows),
--   but the indexes show smaller effects there.
-- In production, use CREATE INDEX CONCURRENTLY (it does not block writes to the table).
-- This file uses a plain CREATE INDEX for learning.
-- It builds indexes on large tables, so the whole file takes a few minutes on sakura_xl.

SET search_path TO sakura, public;

-- ===== 0. Before you create an index, look at the existing ones (avoid duplicates) =====
SELECT tablename, indexname, indexdef FROM pg_indexes
WHERE schemaname = 'sakura' AND tablename IN ('orders', 'order_items', 'behavior_logs')
ORDER BY tablename, indexname;

-- ===== 1. Index types (B-tree is the default. Hash, GIN, GiST, and BRIN have specific uses) =====
-- Hash (equality only): look up a shipment by tracking number.
-- It cannot serve range searches or sorting.
-- Note: users.email already has the B-tree of its UNIQUE constraint.
-- A Hash index there would be a duplicate.
CREATE INDEX IF NOT EXISTS idx_ch10_shipments_tracking_hash ON shipments USING hash (tracking_number);
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, carrier FROM shipments
WHERE tracking_number = (SELECT tracking_number FROM shipments LIMIT 1);

-- GIN (substring search): pg_trgm lets an index serve "name contains ..." searches
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_ch10_products_name_gin ON products USING gin (name_en gin_trgm_ops);
EXPLAIN (ANALYZE, BUFFERS)
SELECT sku, name_en FROM products WHERE name_en LIKE '%M1234%';

-- BRIN (a tiny index for append-only time series): the behavior log is appended in time order.
-- The minimum and maximum time of each block range are enough to narrow the blocks to read.
CREATE INDEX IF NOT EXISTS idx_ch10_behavior_created_brin ON behavior_logs USING brin (created_at);
SELECT attname, correlation FROM pg_stats      -- closer to 1 = physical order matches value order (good for BRIN)
WHERE schemaname = 'sakura' AND tablename = 'behavior_logs' AND attname = 'created_at';
EXPLAIN (ANALYZE, BUFFERS)
SELECT action, count(*) FROM behavior_logs
WHERE created_at >= now() - interval '1 day'
GROUP BY action;
-- Size comparison: BRIN versus the B-tree base indexes on the same table
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND relname = 'behavior_logs'
ORDER BY pg_relation_size(indexrelid) DESC;

-- ===== 2. Multicolumn indexes (equality -> range -> sort) =====
-- "Recent orders of a user": user_id (equality) -> ordered_at (range and sort)
CREATE INDEX IF NOT EXISTS idx_ch10_orders_user_ordered ON orders (user_id, ordered_at DESC);
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, amount, ordered_at FROM orders
WHERE user_id = (SELECT user_id FROM orders ORDER BY ordered_at DESC LIMIT 1)
ORDER BY ordered_at DESC LIMIT 10;
-- "Products in a category by price": category_id (equality) -> price (range and sort)
CREATE INDEX IF NOT EXISTS idx_ch10_products_cat_price ON products (category_id, price);

-- ===== 3. Covering index (INCLUDE for an Index Only Scan) =====
-- Return order amount and time per user from the index alone, without reading the table
CREATE INDEX IF NOT EXISTS idx_ch10_orders_cover
    ON orders (user_id) INCLUDE (amount, ordered_at);
VACUUM (ANALYZE) orders;   -- update the visibility map (required for an Index Only Scan)
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, amount, ordered_at FROM orders ORDER BY user_id LIMIT 100;
-- Success: "Index Only Scan using idx_ch10_orders_cover" and "Heap Fetches: 0"

-- ===== 4. Partial index (with WHERE. Conditions whose value changes, such as now(), are not allowed) =====
-- Unpaid orders (ordered), oldest first (to find orders for reminders or automatic cancellation).
-- Only a few thousand of the 10 million orders go into the index, so it is very small.
CREATE INDEX IF NOT EXISTS idx_ch10_orders_open
    ON orders (ordered_at) WHERE status = 'ordered';
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, amount, ordered_at FROM orders
WHERE status = 'ordered'
ORDER BY ordered_at LIMIT 100;
SELECT pg_size_pretty(pg_relation_size('idx_ch10_orders_open')) AS partial_index_size,
       pg_size_pretty(pg_relation_size('idx_orders_ordered_at')) AS full_index_size;

-- ===== 5. PostgreSQL 18 skip scan (a multicolumn B-tree works without a condition on the leading column) =====
-- It pays off when the leading column has few distinct values.
-- status has only 6 values, so PostgreSQL can walk the (status, ordered_at) index once per status
-- and read the ordered_at range.
CREATE INDEX IF NOT EXISTS idx_ch10_orders_status_ordered ON orders (status, ordered_at);
ANALYZE orders;
-- The single-column index idx_orders_ordered_at also matches this condition and is normally chosen.
-- To see the skip scan alone, drop the single-column index temporarily inside a transaction.
-- (DROP INDEX is also undone by ROLLBACK. While it runs, the whole orders table is locked,
-- so avoid this on a shared database.)
BEGIN;
DROP INDEX idx_orders_ordered_at;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders
WHERE ordered_at >= now() - interval '1 hour';
ROLLBACK;
-- If the plan is "Index Only Scan using idx_ch10_orders_status_ordered"
-- and "Index Searches:" is small (about the number of status values),
-- PostgreSQL skips ahead for each value of the leading column.
-- In contrast, with (user_id, ordered_at) the leading column user_id has many values,
-- so a skip scan does not pay off and is not used.

-- ===== 6. How to check an index suggested by AI (plan, sections 10.7-10.8) =====
-- Is the column order equality -> range -> sort? Does it duplicate an existing index?
-- Did you consider the write cost?
-- Duplicate example: (user_id, created_at DESC) differs from the base index (user_id, created_at)
--   only in direction. A B-tree can be read backward,
--   so the base index serves "user_id = ? ORDER BY created_at DESC".
--   Up to v1.1.1 this file created idx_ch10_behavior_user_desc / product_desc.
--   They are duplicates, so they are no longer created.
EXPLAIN (ANALYZE, BUFFERS)
SELECT action, created_at FROM behavior_logs
WHERE user_id = (SELECT user_id FROM behavior_logs WHERE user_id IS NOT NULL LIMIT 1)
ORDER BY created_at DESC LIMIT 20;
-- -> Index Scan Backward using idx_behavior_logs_user_time (no sort)

-- List candidate duplicates (pairs of indexes on the same table with the same leading column)
SELECT a.indrelid::regclass AS tbl,
       a.indexrelid::regclass AS index_a, b.indexrelid::regclass AS index_b,
       pg_get_indexdef(a.indexrelid) AS def_a, pg_get_indexdef(b.indexrelid) AS def_b
FROM pg_index a
JOIN pg_index b ON b.indrelid = a.indrelid AND b.indexrelid > a.indexrelid
               AND b.indkey[0] = a.indkey[0]
JOIN pg_class t ON t.oid = a.indrelid
WHERE t.relnamespace = 'sakura'::regnamespace
ORDER BY 1, 2;

-- ===== 7. Find unused indexes -> consider DROP =====
SELECT relname, indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'sakura' AND idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC, relname, indexrelname;

-- ===== 8. Final design summary (Sakura Market) =====
-- orders (user_id, ordered_at DESC), order_items (product_id) INCLUDE (order_id, quantity, price),
-- behavior_logs: base indexes (user_id, created_at) and (product_id, created_at) + BRIN (created_at),
-- reviews (product_id), shipments (shipped_at), coupons (expires_at), and the partial index for unpaid orders.
-- Note: once order_items (product_id) INCLUDE (...) exists, the base index idx_order_items_product
--   has the same leading column and is no longer needed
--   (a DROP candidate; it appears in the duplicate list of section 6).
CREATE INDEX IF NOT EXISTS idx_ch10_items_product_cover
    ON order_items (product_id) INCLUDE (order_id, quantity, price);
CREATE INDEX IF NOT EXISTS idx_ch10_shipments_shipped ON shipments (shipped_at);
CREATE INDEX IF NOT EXISTS idx_ch10_coupons_expires ON coupons (expires_at);
