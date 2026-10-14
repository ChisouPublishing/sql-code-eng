-- ch01_ai_errors.sql -- Four typical AI errors and three cases (Chapter 1, sections 1.2-1.3)
-- codes/sql-code-eng/queries/ch01_ai_errors.sql@v1.2.2
-- Prerequisite: init-small is loaded. SELECT only (statements that change data run inside BEGIN).
SET search_path TO sakura, public;

-- ===== Error 1: wrong column (asked for "customer name", returns a column close to the login ID) =====
-- Wrong answer: returns email as the customer name. It runs, but it is wrong for the business.
SELECT email AS customer_name FROM users WHERE rank = 'gold' LIMIT 5;
-- Correct: return the display name
SELECT display_name AS customer_name FROM users WHERE rank = 'gold' LIMIT 5;

-- Wrong money column (v1.2.0 and later): "sales" computed as the sum of orders.amount (amount charged).
-- The amount charged is subtotal - coupon discount + shipping.
-- It does not match sales as this book defines it (sum of order items = product sales).
SELECT SUM(o.amount) AS sum_amount,                 -- wrong: total charged (includes shipping, after discounts)
       SUM(o.subtotal) AS sum_subtotal,             -- correct: product sales (matches the sum of order items)
       SUM(o.discount_amount) AS sum_discount,
       SUM(o.shipping_fee) AS sum_shipping
FROM orders o
WHERE o.status NOT IN ('cancelled', 'returned');

-- ===== Error 2: wrong join (mixing up INNER and LEFT drops or multiplies rows) =====
-- Wrong answer: we want users without orders too, but INNER JOIN drops them
SELECT count(*) AS inner_join_users
FROM users u INNER JOIN orders o ON o.user_id = u.id;
-- Correct: LEFT JOIN and aggregate
SELECT count(DISTINCT u.id) AS all_users,
       count(DISTINCT o.user_id) AS ordered_users
FROM users u LEFT JOIN orders o ON o.user_id = u.id;

-- Fan-out: an unneeded join through categories inflates the order count
SELECT count(*) AS inflated
FROM orders o
INNER JOIN order_items oi ON oi.order_id = o.id
INNER JOIN products p ON oi.product_id = p.id
INNER JOIN categories c ON p.category_id = c.id;
-- Correct: to count orders, count only the orders table
SELECT count(*) AS orders_only FROM orders;

-- ===== Error 3: NULL traps =====
-- COUNT(*) versus COUNT(col): coupon_id is NULL for orders without a coupon.
-- Even the small data set (50 orders) has only some orders with a coupon,
-- so the two numbers differ.
SELECT count(*) AS cnt_star, count(coupon_id) AS cnt_coupon
FROM orders;
-- NULL comparison trap (= NULL yields unknown, so no rows match)
SELECT count(*) AS eq_null_rows FROM products WHERE name_es = NULL;
-- Correct
SELECT count(*) AS is_null_rows FROM products WHERE name_es IS NULL;

-- ===== Error 4: dangerous whole-table changes (UPDATE without WHERE) =====
BEGIN;
UPDATE products SET price = price * 1.1;  -- changes every product!
SELECT count(*) AS affected_all FROM products;  -- check how many rows are affected
ROLLBACK;  -- always undo
-- Correct: narrow the target first, check the count, then COMMIT
BEGIN;
SELECT count(*) AS target FROM products WHERE category_id IN (
    SELECT id FROM categories WHERE name = 'books');
-- UPDATE products SET price = price * 1.1 WHERE ...;
ROLLBACK;

-- ===== Case 1: sales total (the numbers change with how returns and cancellations are handled) =====
-- Wrong answer: no status filter
SELECT SUM(quantity * price) AS sales_naive FROM order_items;
-- Correct (this book's definition): exclude cancelled and returned orders
SELECT SUM(oi.quantity * oi.price) AS sales
FROM order_items oi JOIN orders o ON oi.order_id = o.id
WHERE o.status NOT IN ('cancelled', 'returned');

-- ===== Case 2: repeat rate (wrong join grain counts orders more than once) =====
-- Wrong answer: join to order items, then count.
-- Each order then counts once per line, which inflates the number of purchases.
SELECT count(*) AS users,
       count(*) FILTER (WHERE n >= 2) AS repeat_users_inflated
FROM (SELECT o.user_id, count(*) AS n
      FROM orders o JOIN order_items oi ON oi.order_id = o.id
      WHERE o.ordered_at >= now() - interval '365 days'
      GROUP BY o.user_id) s;
-- Correct (this book's definition): exclude cancelled and returned orders,
-- round to the purchase date (Eastern Time), then count per user
WITH user_days AS (
    SELECT DISTINCT user_id, (ordered_at AT TIME ZONE 'America/New_York')::date AS d FROM orders
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

-- ===== Case 3: out of stock (stock 0 versus no inventory row) =====
-- Count stock 0 (needs a restock) and no inventory row (not stocked) separately
SELECT count(*) FILTER (WHERE i.stock = 0) AS out_of_stock,
       count(*) FILTER (WHERE i.product_id IS NULL) AS no_inventory_row
FROM products p LEFT JOIN inventory i ON i.product_id = p.id
WHERE p.deleted_at IS NULL;
