-- ch12_tuning.sql -- Performance tuning in practice (Chapter 12)
-- codes/sql-code-eng/queries/ch12_tuning.sql@v1.2.2
-- Prerequisite: benchmark database sakura_xl
--   (10 million orders, about 30 million order items, 10 million behavior log rows).
--   psql -d sakura_xl -f queries/ch12_tuning.sql
--   It also runs on the default database (sakura_market).
--   At that size, the rewrites make almost no difference (Chapter 12 section 10).
-- Run times depend on the environment. The book records its measurements in VALIDATION.md
-- and Chapter 12. This file sets no target values.

SET search_path TO sakura, public;

-- ===== 03 Rewrite 1: correlated subquery -> JOIN =====
-- Bad: order count per user with a correlated subquery
EXPLAIN
SELECT u.id, u.display_name,
    (SELECT count(*) FROM orders o WHERE o.user_id = u.id) AS orders
FROM users u LIMIT 100;
-- Good: JOIN and aggregate. GROUP BY the primary key u.id
-- (do not merge different people who share a display name into one row)
EXPLAIN
SELECT u.id, u.display_name, count(o.id) AS orders
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.display_name LIMIT 100;

-- ===== 03 Rewrite 2: IN -> EXISTS / NOT IN -> NOT EXISTS (safe with NULL) =====
-- Bad (NOT IN returns no rows if the subquery returns even one NULL)
EXPLAIN
SELECT id, display_name FROM users WHERE id NOT IN (SELECT user_id FROM orders);
-- Good
EXPLAIN
SELECT u.id, u.display_name FROM users u WHERE NOT EXISTS (
    SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- ===== 03 Rewrite 3: control CTE materialization =====
EXPLAIN
WITH recent_orders AS MATERIALIZED (
    SELECT * FROM orders WHERE ordered_at >= now() - interval '30 days'
)
SELECT count(*) FROM recent_orders;
EXPLAIN
WITH recent_orders AS NOT MATERIALIZED (
    SELECT * FROM orders WHERE ordered_at >= now() - interval '30 days'
)
SELECT count(*) FROM recent_orders;

-- ===== 03 Rewrite 4: filter first in a CTE and reduce the aggregation grain =====
-- Bad form: join the whole period, then filter
-- (the planner often pushes the filter down anyway, so check the plan)
EXPLAIN
SELECT c.name, SUM(oi.quantity * oi.price)
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name;
-- Good: filter the orders first
EXPLAIN
WITH target_orders AS (
    SELECT id FROM orders
    WHERE ordered_at >= now() - interval '30 days'
      AND status NOT IN ('cancelled', 'returned')
)
SELECT c.name, SUM(oi.quantity * oi.price)
FROM target_orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
GROUP BY c.name;

-- ===== 05 Parameters (check and change temporarily) =====
SHOW work_mem;               -- 16MB (compose default)
SHOW shared_buffers;         -- 256MB (compose default)
SHOW effective_cache_size;
-- 06 Asynchronous I/O in PostgreSQL 18: the compose file of this book uses worker
-- (Docker on macOS cannot use io_uring).
-- On a Linux server you can also choose io_uring (a restart is required).
SHOW io_method;              -- worker (compose default)
-- Raise it only for an aggregation query (for one transaction)
-- BEGIN; SET LOCAL work_mem = '128MB'; ... ; COMMIT;

-- ===== 07 Partitioning (monthly partitions of behavior_logs, a demo) =====
-- The primary key and unique constraints of a partitioned table must include
-- the partition key (created_at). The primary key is therefore (id, created_at).
-- Copying the PK(id) with LIKE behavior_logs INCLUDING ALL raises an error.
-- The demo runs between BEGIN and ROLLBACK and leaves nothing in the database.
-- Month boundaries are computed from "now" (the data spreads back in time from the load day).
SELECT to_char(date_trunc('month', now()) - interval '3 months', 'YYYY-MM-DD') AS m0,
       to_char(date_trunc('month', now()) - interval '2 months', 'YYYY-MM-DD') AS m1,
       to_char(date_trunc('month', now()) - interval '1 month', 'YYYY-MM-DD') AS m2,
       to_char(date_trunc('month', now()), 'YYYY-MM-DD') AS m3 \gset
BEGIN;
CREATE TABLE behavior_logs_p (
    id uuid NOT NULL DEFAULT uuidv7(),
    user_id uuid,
    product_id uuid,
    action varchar(30) NOT NULL,
    search_keyword varchar(255),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);
CREATE TABLE behavior_logs_p_m0 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m0') TO (:'m1');
CREATE TABLE behavior_logs_p_m1 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m1') TO (:'m2');
CREATE TABLE behavior_logs_p_m2 PARTITION OF behavior_logs_p FOR VALUES FROM (:'m2') TO (:'m3');
-- Insert a sample of about 3% of three months
INSERT INTO behavior_logs_p (id, user_id, product_id, action, search_keyword, created_at)
SELECT id, user_id, product_id, action, search_keyword, created_at
FROM behavior_logs TABLESAMPLE SYSTEM (3) REPEATABLE (42)
WHERE created_at >= :'m0' AND created_at < :'m3';
ANALYZE behavior_logs_p;
-- Read within one month -> only that partition is scanned
-- (partition pruning. With one partition, the Append node is removed too.)
EXPLAIN (ANALYZE)
SELECT count(*) FROM behavior_logs_p
WHERE created_at >= :'m1'::timestamptz + interval '9 days'
  AND created_at < :'m1'::timestamptz + interval '19 days';
-- Across two months -> two partitions under Append
EXPLAIN (ANALYZE)
SELECT count(*) FROM behavior_logs_p
WHERE created_at >= :'m1'::timestamptz + interval '20 days'
  AND created_at < :'m2'::timestamptz + interval '10 days';
-- Remove an old month: detach and drop instead of DELETE
-- (it finishes at once and does not bloat the table)
ALTER TABLE behavior_logs_p DETACH PARTITION behavior_logs_p_m0;
DROP TABLE behavior_logs_p_m0;
ROLLBACK;

-- ===== 09 Materialized view (store aggregated results) =====
-- Sales by category for all time.
-- The unique index is on category_id (names can repeat under different parents).
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_category_sales AS
SELECT c.id AS category_id,
       c.name AS category_name,
       SUM(oi.quantity * oi.price)::numeric(14, 2) AS total_sales,
       count(DISTINCT o.id)::int AS order_count,
       count(DISTINCT o.user_id)::int AS customer_count,
       now() AS refreshed_at          -- stores the time of the REFRESH
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY c.id, c.name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_category_sales
    ON mv_category_sales (category_id);
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM mv_category_sales ORDER BY total_sales DESC;
-- Refresh (the unique index allows a refresh without blocking readers)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_sales;

-- ===== 10 Full case: improve "sales by category for the last 30 days" step by step =====
-- Save the EXPLAIN (ANALYZE, BUFFERS) output of each step,
-- and record the run time (median of 3 runs).
-- Also confirm that every step returns the same result (the numbers do not change).
-- Step 0: the original SQL
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;

-- Step 1: a CTE that filters first
EXPLAIN (ANALYZE, BUFFERS)
WITH recent_orders AS (
    SELECT id, user_id FROM orders
    WHERE ordered_at >= now() - interval '30 days'
      AND status NOT IN ('cancelled', 'returned')
)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT ro.id) AS order_count,
       COUNT(DISTINCT ro.user_id) AS customer_count
FROM recent_orders ro
JOIN order_items oi ON oi.order_id = ro.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
GROUP BY c.name
ORDER BY total_sales DESC;

-- Step 2: two-step aggregation that avoids COUNT(DISTINCT) (category x order -> category)
EXPLAIN (ANALYZE, BUFFERS)
WITH per_order AS (
    SELECT p.category_id, o.id AS order_id, o.user_id,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.ordered_at >= now() - interval '30 days'
      AND o.status NOT IN ('cancelled', 'returned')
    GROUP BY p.category_id, o.id, o.user_id
)
SELECT c.name AS category_name,
       SUM(po.sales) AS total_sales,
       count(*) AS order_count,
       COUNT(DISTINCT po.user_id) AS customer_count
FROM per_order po
JOIN categories c ON c.id = po.category_id
GROUP BY c.name
ORDER BY total_sales DESC;

-- Step 3: try a partial index (period of orders that are not cancelled or returned).
-- BEGIN to ROLLBACK, so nothing stays.
-- (order_items.order_id can already be looked up with the index of the unique constraint
-- uq_order_items_order_product.)
BEGIN;
CREATE INDEX idx_ch12_orders_recent
    ON orders (ordered_at DESC) INCLUDE (user_id)
    WHERE status NOT IN ('cancelled', 'returned');
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;
SELECT pg_size_pretty(pg_relation_size('idx_ch12_orders_recent')) AS partial_size;
ROLLBACK;

-- Step 4: raise work_mem (for one transaction)
BEGIN;
SET LOCAL work_mem = '128MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.name AS category_name,
       SUM(oi.quantity * oi.price) AS total_sales,
       COUNT(DISTINCT o.id) AS order_count,
       COUNT(DISTINCT o.user_id) AS customer_count
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.name
ORDER BY total_sales DESC;
COMMIT;

-- Step 5: materialized view (last 30 days by category).
-- Reads are fast, but a REFRESH takes as long as the original SQL.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_ch12_category_sales_30d AS
SELECT c.id AS category_id,
       c.name AS category_name,
       SUM(oi.quantity * oi.price)::numeric(14, 2) AS total_sales,
       COUNT(DISTINCT o.id)::int AS order_count,
       COUNT(DISTINCT o.user_id)::int AS customer_count,
       now() AS refreshed_at
FROM order_items oi
JOIN orders o ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
JOIN categories c ON p.category_id = c.id
WHERE o.ordered_at >= now() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'returned')
GROUP BY c.id, c.name;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_ch12_category_sales_30d
    ON mv_ch12_category_sales_30d (category_id);
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ch12_category_sales_30d;
EXPLAIN (ANALYZE, BUFFERS)
SELECT category_name, total_sales, order_count, customer_count
FROM mv_ch12_category_sales_30d ORDER BY total_sales DESC;

-- ===== Tuning checklist (excerpt, see Appendix E) =====
-- [ ] Did you measure with EXPLAIN ANALYZE?
-- [ ] Is there a large gap between estimated and actual rows? (-> ANALYZE)
-- [ ] Do you filter first (WHERE or CTE)?  [ ] Did you stop using SELECT *?  [ ] Did you stop using NOT IN?
-- [ ] Are the indexes used? (Why a Seq Scan: selectivity? statistics?)
-- [ ] Is work_mem large enough? (Sort or Hash spilling to disk)
-- [ ] Did you check the write cost (too many indexes)?  [ ] Did you record before and after numbers?
