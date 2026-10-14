-- ch06_basic_10.sql -- Ten real business queries (Chapter 6, section 6.8)
-- codes/sql-code-eng/queries/ch06_basic_10.sql@v1.2.2
-- Prerequisite: init-small or larger is loaded (default database sakura_market).
-- Definitions: see "Business rules" in README
--   (sales = sum of order items; exclude cancelled/returned; based on ordered_at; Eastern Time).
SET search_path TO sakura, public;

-- Q1 Monthly sales trend (last 12 months, with month-over-month change)
-- Use only closed months: from the first day of this month (Eastern Time) minus 12 months,
-- up to but not including the first day of this month.
-- If you cut at now() - interval '12 months', the first month and this month are partial,
-- and the month-over-month change is badly distorted.
WITH bounds AS (
    SELECT (date_trunc('month', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York') AS this_month
),
monthly AS (
    SELECT date_trunc('month', o.ordered_at AT TIME ZONE 'America/New_York')::date AS m,
           SUM(oi.quantity * oi.price)::numeric(14, 2) AS sales
    FROM orders o JOIN order_items oi ON oi.order_id = o.id
    CROSS JOIN bounds b
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= b.this_month - interval '12 months'
      AND o.ordered_at < b.this_month
    GROUP BY 1
)
SELECT m, sales,
       LAG(sales) OVER (ORDER BY m) AS prev_sales,
       round(100.0 * (sales - LAG(sales) OVER (ORDER BY m))
             / NULLIF(LAG(sales) OVER (ORDER BY m), 0), 2) AS mom_pct
FROM monthly ORDER BY m;

-- Q2 Sales share by category
WITH cat_sales AS (
    SELECT c.name AS category_name, SUM(oi.quantity * oi.price)::numeric(14, 2) AS sales
    FROM order_items oi
    JOIN orders o ON oi.order_id = o.id
    JOIN products p ON oi.product_id = p.id
    JOIN categories c ON p.category_id = c.id
    WHERE o.status NOT IN ('cancelled', 'returned')
    GROUP BY c.name
)
SELECT category_name, sales,
       round(100.0 * sales / NULLIF(SUM(sales) OVER (), 0), 2) AS share_pct
FROM cat_sales ORDER BY sales DESC;

-- Q3 Repeat rate (past 365 days, users who bought two or more times)
WITH user_days AS (
    SELECT DISTINCT user_id, ordered_at::date AS d FROM orders
    WHERE ordered_at >= now() - interval '365 days'
      AND status NOT IN ('cancelled', 'returned')
),
user_counts AS (
    SELECT user_id, count(*) AS order_count FROM user_days GROUP BY user_id
)
SELECT count(*) AS users,
       count(*) FILTER (WHERE order_count >= 2) AS repeat_users,
       round(100.0 * count(*) FILTER (WHERE order_count >= 2) / NULLIF(count(*), 0), 2) AS repeat_rate_pct
FROM user_counts;

-- Q4 Simple customer lifetime value (LTV) by rank
WITH user_sales AS (
    SELECT u.id, u.rank, COALESCE(SUM(oi.quantity * oi.price), 0)::numeric(14, 2) AS ltv
    FROM users u
    LEFT JOIN orders o ON o.user_id = u.id AND o.status NOT IN ('cancelled', 'returned')
    LEFT JOIN order_items oi ON oi.order_id = o.id
    GROUP BY u.id, u.rank
)
SELECT rank,
       count(*) AS users,
       round(AVG(ltv), 2) AS avg_ltv,
       MAX(ltv) AS max_ltv
FROM user_sales GROUP BY rank ORDER BY avg_ltv DESC;

-- Q5 Cart abandonment (user x product added to the cart in the last 30 days but not bought)
WITH cart AS (
    SELECT DISTINCT user_id, product_id FROM behavior_logs
    WHERE action = 'add_to_cart'
      AND created_at >= now() - interval '30 days'
      AND user_id IS NOT NULL AND product_id IS NOT NULL
),
purchased AS (
    SELECT DISTINCT o.user_id, oi.product_id
    FROM orders o JOIN order_items oi ON oi.order_id = o.id
    WHERE o.status NOT IN ('cancelled', 'returned')
      AND o.ordered_at >= now() - interval '30 days'
)
SELECT c.user_id, c.product_id
FROM cart c LEFT JOIN purchased pu
  ON pu.user_id = c.user_id AND pu.product_id = c.product_id
WHERE pu.user_id IS NULL
LIMIT 100;

-- Q6 Return rate by product (products with 10 or more orders)
-- The denominator is "orders that were not cancelled". Returned orders stay in the denominator.
-- (Removing them would overstate the return rate.)
WITH order_counts AS (
    SELECT oi.product_id, count(DISTINCT oi.order_id) AS order_count
    FROM order_items oi JOIN orders o ON oi.order_id = o.id
    WHERE o.status <> 'cancelled'
    GROUP BY oi.product_id
),
return_counts AS (
    SELECT oi.product_id, count(DISTINCT r.id) AS return_count
    FROM returns r
    JOIN orders o ON r.order_id = o.id
    JOIN order_items oi ON oi.order_id = o.id
    GROUP BY oi.product_id
)
SELECT p.sku, p.name_en, oc.order_count,
       COALESCE(rc.return_count, 0) AS return_count,
       round(100.0 * COALESCE(rc.return_count, 0) / NULLIF(oc.order_count, 0), 2) AS return_rate_pct
FROM order_counts oc
JOIN products p ON p.id = oc.product_id
LEFT JOIN return_counts rc ON rc.product_id = oc.product_id
WHERE oc.order_count >= 10
ORDER BY return_rate_pct DESC, p.sku
LIMIT 20;

-- Q7 Average order amount by rank (orders.amount = amount charged: subtotal - discount + shipping)
SELECT u.rank,
       count(*) AS orders,
       round(AVG(o.amount), 2) AS avg_amount,
       MIN(o.amount) AS min_amount,
       MAX(o.amount) AS max_amount
FROM orders o JOIN users u ON o.user_id = u.id
WHERE o.status NOT IN ('cancelled', 'returned')
GROUP BY u.rank ORDER BY avg_amount DESC;

-- Q8 Orders by hour of day (Eastern Time, last 90 days)
SELECT EXTRACT(HOUR FROM ordered_at AT TIME ZONE 'America/New_York')::int AS hour_et,
       count(*) AS orders
FROM orders
WHERE ordered_at >= now() - interval '90 days'
GROUP BY 1 ORDER BY 1;

-- Q9 Coupon usage rate (only coupons with a limit have a rate. No limit (NULL) sorts last.)
-- used = uses in orders that were not cancelled. It matches coupons.used_count (checked in checks).
SELECT c.code, c.max_uses,
       count(o.id) AS used,
       sum(o.discount_amount) AS total_discount,
       round(100.0 * count(o.id) / NULLIF(c.max_uses, 0), 2) AS usage_pct
FROM coupons c
LEFT JOIN orders o ON o.coupon_id = c.id AND o.status <> 'cancelled'
GROUP BY c.code, c.max_uses ORDER BY usage_pct DESC NULLS LAST, c.code;

-- Q10 Low stock (10 or fewer units, active products)
SELECT p.sku, p.name_en, c.name AS category_name, i.stock
FROM inventory i
JOIN products p ON p.id = i.product_id
LEFT JOIN categories c ON p.category_id = c.id
WHERE i.stock <= 10 AND p.deleted_at IS NULL
ORDER BY i.stock, p.sku
LIMIT 20;
