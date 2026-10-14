-- ch14_dashboard.sql -- Capstone: a real-time sales dashboard (Chapter 14)
-- codes/sql-code-eng/queries/ch14_dashboard.sql@v1.2.2
-- Requirements: sales, order count, customer count, change from the previous period,
-- and refresh time by category / refreshed within 5 minutes /
-- 100 requests per minute / last 30 days / response within 100 ms.
-- Definitions: sales = SUM(qty * price) in USD (before discounts, without shipping);
--   exclude cancelled/returned; based on ordered_at; dates in Eastern Time (America/New_York).
--   Last 30 days = 30 days including today (29 days up to yesterday + today).
--   Previous period = the 30 days before that.
-- Prerequisite: benchmark database sakura_xl (10 million orders).
--   It also runs on the default database sakura_market.
-- Safe to run more than once (tables use IF NOT EXISTS, aggregates use UPSERT,
-- and the materialized view is refreshed at the end).

SET search_path TO sakura, public;

-- ===== Layer 1: summary tables (daily + today) =====
CREATE TABLE IF NOT EXISTS daily_category_sales (
    category_id uuid NOT NULL REFERENCES categories (id),
    sale_date date NOT NULL,                 -- date in Eastern Time
    total_sales numeric(14, 2) NOT NULL DEFAULT 0,
    order_count int NOT NULL DEFAULT 0,
    customer_count int NOT NULL DEFAULT 0,   -- customers on that day (summing across days counts people twice)
    refreshed_at timestamptz NOT NULL DEFAULT now(),   -- when this row was aggregated
    PRIMARY KEY (category_id, sale_date)
);
CREATE INDEX IF NOT EXISTS idx_daily_category_sales_date
    ON daily_category_sales (sale_date DESC, category_id);

CREATE TABLE IF NOT EXISTS today_category_sales (
    category_id uuid NOT NULL PRIMARY KEY REFERENCES categories (id),
    total_sales numeric(14, 2) NOT NULL DEFAULT 0,
    order_count int NOT NULL DEFAULT 0,
    customer_count int NOT NULL DEFAULT 0,
    refreshed_at timestamptz NOT NULL DEFAULT now()
);

-- ===== Refresh 1: backfill (once at go-live. The past 61 days needed for the period comparison) =====
-- Write the period as a range condition on ordered_at.
-- Do not wrap the column in a function, so the index idx_orders_ordered_at can be used.
INSERT INTO daily_category_sales (category_id, sale_date, total_sales, order_count, customer_count)
SELECT p.category_id, (o.ordered_at AT TIME ZONE 'America/New_York')::date AS sale_date,
       SUM(oi.quantity * oi.price)::numeric(14, 2),
       count(DISTINCT o.id)::int,
       count(DISTINCT o.user_id)::int
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
WHERE o.status NOT IN ('cancelled', 'returned')
  AND o.ordered_at >= (((now() AT TIME ZONE 'America/New_York')::date - 61)::timestamp AT TIME ZONE 'America/New_York')
  AND o.ordered_at <  (((now() AT TIME ZONE 'America/New_York')::date)::timestamp AT TIME ZONE 'America/New_York')
GROUP BY p.category_id, sale_date
ON CONFLICT (category_id, sale_date) DO UPDATE SET
    total_sales = EXCLUDED.total_sales,
    order_count = EXCLUDED.order_count,
    customer_count = EXCLUDED.customer_count,
    refreshed_at = now();

-- ===== Refresh 2: UPSERT yesterday (once a day, just after midnight) =====
-- If returns and cancellations change past days later, widen the range
-- to "from a few days ago" and load it again.
INSERT INTO daily_category_sales (category_id, sale_date, total_sales, order_count, customer_count)
SELECT p.category_id, (o.ordered_at AT TIME ZONE 'America/New_York')::date AS sale_date,
       SUM(oi.quantity * oi.price)::numeric(14, 2),
       count(DISTINCT o.id)::int,
       count(DISTINCT o.user_id)::int
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p ON oi.product_id = p.id
WHERE o.status NOT IN ('cancelled', 'returned')
  AND o.ordered_at >= (((now() AT TIME ZONE 'America/New_York')::date - 1)::timestamp AT TIME ZONE 'America/New_York')
  AND o.ordered_at <  (((now() AT TIME ZONE 'America/New_York')::date)::timestamp AT TIME ZONE 'America/New_York')
GROUP BY p.category_id, sale_date
ON CONFLICT (category_id, sale_date) DO UPDATE SET
    total_sales = EXCLUDED.total_sales,
    order_count = EXCLUDED.order_count,
    customer_count = EXCLUDED.customer_count,
    refreshed_at = now();

-- ===== Refresh 3: today (every 5 minutes; rebuilt each time) =====
-- Start from categories with a LEFT JOIN, so categories without orders get 0.
-- The table is never empty, so its freshness can be monitored.
-- The swap runs in one transaction. Readers see either the old or the new data for today.
BEGIN;
TRUNCATE today_category_sales;
INSERT INTO today_category_sales (category_id, total_sales, order_count, customer_count)
SELECT c.id,
       COALESCE(t.total_sales, 0),
       COALESCE(t.order_count, 0),
       COALESCE(t.customer_count, 0)
FROM categories c
LEFT JOIN (
    SELECT p.category_id,
           SUM(oi.quantity * oi.price)::numeric(14, 2) AS total_sales,
           count(DISTINCT o.id)::int AS order_count,
           count(DISTINCT o.user_id)::int AS customer_count
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= (((now() AT TIME ZONE 'America/New_York')::date)::timestamp AT TIME ZONE 'America/New_York')
    GROUP BY p.category_id
) t ON t.category_id = c.id;
COMMIT;

-- ===== Layer 2: reporting view (last 30 days + previous period + growth rate) =====
-- Sales and order counts can be summed across days (each order belongs to one day only).
-- Customer counts cannot (a person who buys on two days would count as two),
-- so count distinct customers over the period from the source data.
-- Reading the source data makes this view heavy. The screen reads the layer 3 materialized view.
-- refreshed_at is the time the summary tables were built (not the read time now()).
CREATE OR REPLACE VIEW v_category_sales_dashboard AS
WITH bounds AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS today
),
cur AS (
    SELECT d.category_id,
           SUM(d.total_sales)::numeric(14, 2) AS sales,
           SUM(d.order_count)::int AS orders,
           MIN(d.refreshed_at) AS refreshed_at
    FROM daily_category_sales d CROSS JOIN bounds b
    WHERE d.sale_date >= b.today - 29 AND d.sale_date < b.today
    GROUP BY d.category_id
),
prev AS (
    SELECT d.category_id, SUM(d.total_sales)::numeric(14, 2) AS sales
    FROM daily_category_sales d CROSS JOIN bounds b
    WHERE d.sale_date >= b.today - 59 AND d.sale_date < b.today - 29
    GROUP BY d.category_id
),
customers AS (
    SELECT p.category_id, count(DISTINCT o.user_id)::int AS customers
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    CROSS JOIN bounds b
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= ((b.today - 29)::timestamp AT TIME ZONE 'America/New_York')
    GROUP BY p.category_id
)
SELECT c.id AS category_id,
       c.name AS category_name,
       COALESCE(cur.sales, 0) + COALESCE(t.total_sales, 0) AS total_sales,
       COALESCE(cur.orders, 0) + COALESCE(t.order_count, 0) AS order_count,
       COALESCE(cu.customers, 0) AS customer_count,
       COALESCE(prev.sales, 0) AS prev_sales,
       round(100.0 * ((COALESCE(cur.sales, 0) + COALESCE(t.total_sales, 0)) - prev.sales)
             / NULLIF(prev.sales, 0), 2) AS growth_pct,
       LEAST(cur.refreshed_at, t.refreshed_at) AS refreshed_at   -- the older of the two refresh times
FROM categories c
LEFT JOIN cur ON cur.category_id = c.id
LEFT JOIN prev ON prev.category_id = c.id
LEFT JOIN today_category_sales t ON t.category_id = c.id
LEFT JOIN customers cu ON cu.category_id = c.id;

-- ===== Layer 3: materialized view (the screen reads this; within 100 ms) =====
-- The unique index is on category_id (category names can repeat under different parents).
-- REFRESH ... CONCURRENTLY requires it.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_category_sales_dashboard AS
SELECT * FROM v_category_sales_dashboard;
CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_dashboard
    ON mv_category_sales_dashboard (category_id);
-- Refresh here too, so a second run is also up to date
-- (CREATE ... IF NOT EXISTS does not refresh an existing materialized view).
-- Refresh order: layer 1 (refreshes 1 to 3) -> layer 3.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_sales_dashboard;

-- Read the dashboard
EXPLAIN (ANALYZE, BUFFERS)
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, refreshed_at
FROM mv_category_sales_dashboard ORDER BY total_sales DESC;
SELECT category_name, total_sales, order_count, customer_count, prev_sales, growth_pct, refreshed_at
FROM mv_category_sales_dashboard ORDER BY total_sales DESC;

-- ===== Operations (schedule with pg_cron if available) =====
DO
$do$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;
        PERFORM cron.schedule('dash-daily', '5 0 * * *',
            $$SELECT 1$$);  -- in production, schedule refresh 2
        PERFORM cron.schedule('dash-today', '*/5 * * * *',
            $$SELECT 1$$);  -- in production, schedule refresh 3 and REFRESH MATERIALIZED VIEW CONCURRENTLY
    ELSE
        RAISE NOTICE 'pg_cron not available; refresh manually';
    END IF;
END;
$do$;

-- ===== Monitoring (freshness and slow queries) =====
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT MAX(refreshed_at) AS daily_last_refresh FROM daily_category_sales;
SELECT queryid, calls, round(mean_exec_time::numeric, 2) AS mean_ms
FROM pg_stat_statements
WHERE query LIKE '%mv_category_sales_dashboard%'
ORDER BY mean_exec_time DESC LIMIT 10;
-- Freshness alert (warn if today's data is older than 10 minutes or empty)
DO
$do$
DECLARE
    last_refresh timestamptz;
BEGIN
    SELECT MAX(refreshed_at) INTO last_refresh FROM sakura.today_category_sales;
    IF last_refresh IS NULL OR last_refresh < now() - interval '10 minutes' THEN
        RAISE WARNING 'today_category_sales is stale: last_refresh=%', last_refresh;
    ELSE
        RAISE NOTICE 'today_category_sales is fresh: last_refresh=%', last_refresh;
    END IF;
END;
$do$;

-- ===== Load test (with the steps of Chapter 13) =====
-- docker run --rm --network sql-code-eng_default -e PGPASSWORD=sakura_dev -v "$PWD/bench:/bench:ro" postgres:18 \
--   pgbench -n -c 50 -j 8 -T 300 -f /bench/dashboard_bench.sql -U sakura -d sakura_xl -h sakura_market_db
-- Measurements are in VALIDATION.md (they depend on the environment).
