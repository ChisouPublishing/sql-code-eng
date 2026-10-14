-- ch07_ai_design_3cases.sql -- Three designs for the same requirement (Chapter 7, section 7.4)
-- codes/sql-code-eng/queries/ch07_ai_design_3cases.sql@v1.2.2
-- Requirement: show sales by category for the last 30 days,
-- with the change from the previous 30 days.
-- Definition: sales = SUM(qty * price); exclude cancelled/returned; based on ordered_at.
-- Prerequisite: default database sakura_market (small + medium).
SET search_path TO sakura, public;

-- Design A: many subqueries (simple, hard to read).
-- Reads orders and order items again for each category, twice.
SELECT category_name, sales_30d, sales_prev_30d,
       round(100.0 * (sales_30d - sales_prev_30d) / NULLIF(sales_prev_30d, 0), 2) AS growth_pct
FROM (
    SELECT c.name AS category_name,
        (SELECT COALESCE(SUM(oi.quantity * oi.price), 0)
         FROM orders o JOIN order_items oi ON oi.order_id = o.id
         JOIN products p ON oi.product_id = p.id
         WHERE p.category_id = c.id
           AND o.status NOT IN ('cancelled', 'returned')
           AND o.ordered_at >= now() - interval '30 days') AS sales_30d,
        (SELECT COALESCE(SUM(oi.quantity * oi.price), 0)
         FROM orders o JOIN order_items oi ON oi.order_id = o.id
         JOIN products p ON oi.product_id = p.id
         WHERE p.category_id = c.id
           AND o.status NOT IN ('cancelled', 'returned')
           AND o.ordered_at >= now() - interval '60 days'
           AND o.ordered_at < now() - interval '30 days') AS sales_prev_30d
    FROM categories c
) AS a
ORDER BY sales_30d DESC, category_name;

-- Design B: organized with CTEs (readable and easy to maintain).
-- Reads orders once and splits them into the two periods with FILTER.
WITH target_orders AS (
    SELECT o.id, o.ordered_at FROM orders o
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '60 days'
),
sales AS (
    SELECT p.category_id,
           SUM(oi.quantity * oi.price)
               FILTER (WHERE o.ordered_at >= now() - interval '30 days') AS sales_30d,
           SUM(oi.quantity * oi.price)
               FILTER (WHERE o.ordered_at < now() - interval '30 days') AS sales_prev_30d
    FROM target_orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    GROUP BY p.category_id
)
SELECT c.name AS category_name,
       COALESCE(s.sales_30d, 0) AS sales_30d,
       COALESCE(s.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(s.sales_30d, 0) - COALESCE(s.sales_prev_30d, 0))
             / NULLIF(s.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN sales s ON s.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- Design C [WRONG EXAMPLE, kept for teaching]: aggregate by day, then sum into two periods.
-- AI tools often suggest this ("pre-aggregate by day, it is faster").
-- The performance idea is sound, but the period boundaries shift:
--   (1) o.ordered_at::date depends on the session TimeZone (a hidden dependency).
--   (2) (now() - interval '30 days')::date rounds the boundary down to midnight.
--       The last 30 days get up to one extra day, and the previous 30 days lose it.
--       The numbers then differ from designs A and B.
WITH daily AS (
    SELECT p.category_id, o.ordered_at::date AS d,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '60 days'
    GROUP BY p.category_id, o.ordered_at::date
),
agg AS (
    SELECT category_id,
           SUM(sales) FILTER (WHERE d >= (now() - interval '30 days')::date) AS sales_30d,
           SUM(sales) FILTER (WHERE d < (now() - interval '30 days')::date) AS sales_prev_30d
    FROM daily GROUP BY category_id
)
SELECT c.name AS category_name,
       COALESCE(a.sales_30d, 0) AS sales_30d,
       COALESCE(a.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(a.sales_30d, 0) - COALESCE(a.sales_prev_30d, 0))
             / NULLIF(a.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN agg a ON a.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- Design C' (fixed): keep the two-step aggregation, but define the periods by Eastern Time dates.
--   Last 30 days = the 30 days up to yesterday [today - 30, today).
--   Previous 30 days = [today - 60, today - 30). Eastern Time, half-open intervals.
--   This form moves directly onto the daily table of Chapter 14 (daily_category_sales).
--   Note: this is a different definition from "30 days before this moment" (designs A and B).
--   Choose one based on the requirement, and state it.
WITH bounds AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS today
),
daily AS (
    SELECT p.category_id, (o.ordered_at AT TIME ZONE 'America/New_York')::date AS d,
           SUM(oi.quantity * oi.price) AS sales
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    CROSS JOIN bounds b
    -- Filter on a time range. The index idx_orders_ordered_at can be used.
    -- Do not wrap the column in a function.
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= (b.today - 60) AT TIME ZONE 'America/New_York'
      AND o.ordered_at < b.today AT TIME ZONE 'America/New_York'
    GROUP BY p.category_id, (o.ordered_at AT TIME ZONE 'America/New_York')::date
),
agg AS (
    SELECT category_id,
           SUM(sales) FILTER (WHERE d >= b.today - 30) AS sales_30d,
           SUM(sales) FILTER (WHERE d < b.today - 30) AS sales_prev_30d
    FROM daily CROSS JOIN bounds b
    GROUP BY category_id
)
SELECT c.name AS category_name,
       COALESCE(a.sales_30d, 0) AS sales_30d,
       COALESCE(a.sales_prev_30d, 0) AS sales_prev_30d,
       round(100.0 * (COALESCE(a.sales_30d, 0) - COALESCE(a.sales_prev_30d, 0))
             / NULLIF(a.sales_prev_30d, 0), 2) AS growth_pct
FROM categories c LEFT JOIN agg a ON a.category_id = c.id
ORDER BY sales_30d DESC, category_name;

-- Cross-check: compare the totals of design B and design C.
-- A nonzero difference shows the boundary shift of design C in the numbers.
SELECT
    (SELECT SUM(oi.quantity * oi.price) FROM orders o JOIN order_items oi ON oi.order_id = o.id
     WHERE o.status NOT IN ('cancelled', 'returned')
       AND o.ordered_at >= now() - interval '30 days') AS b_sales_30d,
    (SELECT SUM(oi.quantity * oi.price) FROM orders o JOIN order_items oi ON oi.order_id = o.id
     WHERE o.status NOT IN ('cancelled', 'returned')
       AND o.ordered_at >= now() - interval '60 days'
       AND o.ordered_at::date >= (now() - interval '30 days')::date) AS c_sales_30d;

-- Comparison (plan, section 7.4): readability A fair / B good / C good;
-- performance A fair / B good / C best; maintainability A fair / B good / C good;
-- PostgreSQL dependence: low for all three.
-- Choice: this book uses design B as the standard. For large data, move on to design C'
-- (daily aggregation) with summary tables and materialized views (Chapters 12 and 14).
